defmodule Custode.Repository do
  @moduledoc """
  "Serve a repo" (issue #10): each repo-tied project runs as its own
  GenServer, and the write verbs are calls on it. The process mailbox
  serializes every mutation per repo -- two agents can no longer race
  writes -- and gives policy (#50) one mechanical chokepoint: every verb
  consults the repo's binding policies BEFORE acting and refuses with the
  rule named, so a calling agent can quote exactly why.

  Verbs go through gh_ex with the operator token: the caller needs no
  shell or git elevation for typed operations. This is the middle ground
  between implicit agent action and gating every step -- policy-safe verbs
  act directly; everything else still gates.

  Write verbs: `open_pr/3`, `comment/4`, `ready_pr/3`, `merge_pr/3`.
  Read verbs (#129): `list_issues/2`, `view_issue/2`, `list_prs/2`,
  `view_pr/2`, `pr_checks/2`, `job_log_tail/2`, `pr_diff/2`,
  `review_snapshot/2` -- scoped
  GitHub reads through the bound server, replacing the unscoped
  `gh issue list` / `gh pr view` Bash grants. `Custode.GitHub` still owns the
  dashboard panel fetcher/cache.
  """

  use GenServer

  @registry Custode.Repository.Registry

  @type actor :: %{required(:kind) => atom(), required(:id) => String.t()}

  # ---------------------------------------------------------------------------
  # supervision
  # ---------------------------------------------------------------------------

  defmodule Supervisor do
    @moduledoc false
    use Elixir.Supervisor

    def start_link(opts), do: Elixir.Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl Elixir.Supervisor
    def init(_opts) do
      children =
        [{Registry, keys: :unique, name: Custode.Repository.Registry}] ++
          for repo <- Custode.Repository.served_repos() do
            Elixir.Supervisor.child_spec({Custode.Repository, repo},
              id: {Custode.Repository, repo.name}
            )
          end

      Elixir.Supervisor.init(children, strategy: :one_for_one)
    end
  end

  @doc "The served repos, derived from the routines' repo: fields (one per repo)."
  def served_repos do
    Custode.Routine.all()
    |> Enum.filter(&is_binary(&1.repo))
    |> Enum.uniq_by(& &1.repo)
    |> Enum.map(&%{name: &1.repo, routine_id: &1.id})
  end

  def start_link(repo), do: GenServer.start_link(__MODULE__, repo, name: via(repo.name))

  defp via(name), do: {:via, Registry, {@registry, name}}

  @doc """
  `owner/name` as an agent declared it (#542), or nil when it is not that
  shape. A model can send anything past a schema, and the value ends up in a
  GitHub path, so junk is dropped rather than repaired.
  """
  def well_formed(name) when is_binary(name) do
    if Regex.match?(~r{\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+\z}, name), do: name
  end

  def well_formed(_other), do: nil

  @doc "Is this repo served? (Only served repos can be written to at all.)"
  def served?(name), do: match?([{_pid, _value}], Registry.lookup(@registry, name))

  @doc """
  Start the server for a repo added at runtime (#221): boot starts one per
  served repo, but a conversational add_routine lands after boot -- without
  this, the newcomer's repo_* verbs refuse "not served" until a restart.
  Idempotent; a no-op when the repo is already served.
  """
  def ensure_served(name, routine_id) when is_binary(name) do
    if served?(name) do
      :ok
    else
      spec =
        Elixir.Supervisor.child_spec({__MODULE__, %{name: name, routine_id: routine_id}},
          id: {__MODULE__, name}
        )

      case Elixir.Supervisor.start_child(__MODULE__.Supervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Stop serving a repo when its last routine leaves the roster (#221's
  inverse). A no-op when other routines still serve it or no server runs.
  """
  def stop_serving(name) when is_binary(name) do
    still_served? = Enum.any?(served_repos(), &(&1.name == name))

    if still_served? or not served?(name) do
      :ok
    else
      _terminated = Elixir.Supervisor.terminate_child(__MODULE__.Supervisor, {__MODULE__, name})
      _deleted = Elixir.Supervisor.delete_child(__MODULE__.Supervisor, {__MODULE__, name})
      # terminate_child returns once the process is dead, but the Registry
      # deregisters on the process's DOWN, which is async -- so served?/1 can
      # briefly still report true. Wait it out so "after stop_serving, the
      # repo is not served" is a real guarantee callers (and tests) can rely
      # on, not a race.
      await_deregistered(name)
    end
  end

  defp await_deregistered(name, attempts \\ 50) do
    cond do
      not served?(name) ->
        :ok

      attempts <= 0 ->
        :ok

      true ->
        Process.sleep(2)
        await_deregistered(name, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # verbs
  # ---------------------------------------------------------------------------

  @doc """
  Open a PR. `attrs`: title, head, base (defaults "main"), body.
  Policy: conventional title enforced; draft forced when draft_pr_first
  binds (which it should).
  """
  @spec open_pr(String.t(), map(), actor()) :: {:ok, term()} | {:error, term()}
  def open_pr(name, attrs, actor), do: write_call(name, actor, {:open_pr, attrs})

  @doc """
  Open an ISSUE (#235): the fleet's "create a backlog" primitive, not just
  comment on one. `attrs`: title (conventional-commit style, enforced),
  body, labels (list). Policy-checked like open_pr.
  """
  @spec open_issue(String.t(), map(), actor()) :: {:ok, term()} | {:error, term()}
  def open_issue(name, attrs, actor), do: write_call(name, actor, {:open_issue, attrs})

  @doc "Comment on an issue or PR by number."
  @spec comment(String.t(), pos_integer(), String.t(), actor()) ::
          {:ok, term()} | {:error, term()}
  def comment(name, number, body, actor), do: write_call(name, actor, {:comment, number, body})

  @doc "Mark a draft PR ready for review."
  @spec ready_pr(String.t(), pos_integer(), actor()) :: {:ok, term()} | {:error, term()}
  def ready_pr(name, number, actor), do: write_call(name, actor, {:ready_pr, number})

  @doc "The issue's ready transition (#86): posts a `ready: <plan>` comment."
  def mark_issue_ready(name, number, plan, actor),
    do: comment(name, number, "ready: " <> plan, actor)

  @doc "The issue's blocked transition (#86): posts a `blocked: <reason>` comment."
  def mark_issue_blocked(name, number, reason, actor),
    do: comment(name, number, "blocked: " <> reason, actor)

  @doc """
  The review transition (#86): posts a `review:` marker the merge floor
  reads. `verdict` is "lgtm" (or any ok text) or "needs-human"; the body
  carries findings.
  """
  def review_pr(name, number, verdict, body, actor) do
    prefix =
      case verdict do
        "needs-human" -> "review: needs-human -- "
        other -> "review: #{other} -- "
      end

    comment(name, number, prefix <> body, actor)
  end

  @doc "Merge a PR. Refused wherever the merge policy is :manual."
  @spec merge_pr(String.t(), pos_integer(), actor()) :: {:ok, term()} | {:error, term()}
  def merge_pr(name, number, actor), do: write_call(name, actor, {:merge_pr, number})

  # The exact-head seam behind the merge Gate (#674): the method is the one the
  # Gate pinned, re-checked against the repository and sent exactly, never
  # reselected.
  @doc false
  def merge_pr_at_head(name, number, head_sha, merge_method, actor),
    do: write_call(name, actor, {:merge_pr_at_head, number, head_sha, merge_method})

  # ---------------------------------------------------------------------------
  # read verbs (issue #129): scoped GitHub reads through the bound server
  # ---------------------------------------------------------------------------
  #
  # These fold the gh read grants (`gh issue list`, `gh pr view`, ...) into the
  # verb layer. Unlike a Bash gh grant -- which is unscoped, so any routine can
  # read any repo -- a read verb is bound to this repo's server by construction,
  # the same scoping the write verbs get. Reads take no policy check (nothing
  # to refuse) and do NOT record a feed entry: they are frequent and
  # side-effect-free, and per-read feed spam would drown the state-change
  # signal the feed exists for. The GenServer seat is the point of entry a
  # later slice can hang a per-sweep response cache on.

  @doc "List issues (defaults to open, oldest first). `opts`: `:state`."
  def list_issues(name, opts \\ %{}), do: call(name, {:list_issues, opts})

  @doc """
  The label that withholds an issue from the fleet's survey (#334).

  A GitHub label rather than custode config, on purpose: the operator marks
  it where they are already reading the issue, it needs no roster edit and no
  restart, and it survives anything that happens to this machine. It is also
  visible to collaborators, which is a feature when a repo has any and worth
  knowing when it does not.
  """
  def ignore_label, do: Application.get_env(:custode, :ignore_label, "custode:ignore")

  @doc """
  Split issues into `{kept, ignored}` by the ignore label (#334).

  Pure, and public so the decision is tested directly rather than mirrored in
  a test that can drift from it.

      iex> Custode.Repository.partition_ignored(
      ...>   [%{number: 1, labels: []}, %{number: 2, labels: ["custode:ignore"]}],
      ...>   "custode:ignore"
      ...> )
      {[%{number: 1, labels: []}], [%{number: 2, labels: ["custode:ignore"]}]}
  """
  def partition_ignored(issues, label) do
    Enum.split_with(issues, &(label not in (&1[:labels] || [])))
  end

  @doc "View one issue: title, state, labels, body, and its comments."
  def view_issue(name, number), do: call(name, {:view_issue, number})

  @doc "List pull requests (defaults to open, oldest first). `opts`: `:state`."
  def list_prs(name, opts \\ %{}), do: call(name, {:list_prs, opts})

  @doc "View one PR: title, state, draft, base/head, body."
  def view_pr(name, number), do: call(name, {:view_pr, number})

  @doc "The check runs on a PR's head commit (name, status, conclusion)."
  def pr_checks(name, number), do: call(name, {:pr_checks, number})

  @doc "A bounded tail of one GitHub Actions job log."
  def job_log_tail(name, job_id), do: call(name, {:job_log_tail, job_id})

  @doc "The changed files of a PR, each with its patch (the diff)."
  def pr_diff(name, number), do: call(name, {:pr_diff, number})

  @doc "Identifier-rich PR, review, comment, and check evidence for reconciliation."
  def review_snapshot(name, number), do: call(name, {:review_snapshot, number})

  defp write_call(name, %{kind: kind, id: id} = actor, request)
       when is_atom(kind) and is_binary(id) and id != "" do
    call(name, {:write, actor, request})
  end

  defp write_call(_name, _actor, _request),
    do: {:error, "repository mutation requires an actor with kind and id"}

  defp call(name, request) do
    if served?(name) do
      GenServer.call(via(name), request, 30_000)
    else
      {:error, "repo #{name} is not served (no routine is tied to it)"}
    end
  end

  # ---------------------------------------------------------------------------
  # server
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(repo) do
    [owner, bare] = String.split(repo.name, "/", parts: 2)
    {:ok, %{name: repo.name, owner: owner, repo: bare, routine_id: repo.routine_id}}
  end

  @impl GenServer
  def handle_call({:write, actor, {:open_pr, attrs}}, _from, state) do
    title = to_string(get(attrs, :title) || "")

    case check(state, :open_pr, title) do
      :ok ->
        pr_attrs = %{
          title: title,
          head: get(attrs, :head),
          base: get(attrs, :base) || "main",
          body: get(attrs, :body) || "",
          # draft_pr_first is policy for every served repo; force it
          draft: true
        }

        state |> ops_result(actor, :open_pr, [state.owner, state.repo, pr_attrs]) |> reply(state)

      refusal ->
        reply(refusal, state)
    end
  end

  def handle_call({:write, actor, {:open_issue, attrs}}, _from, state) do
    title = to_string(get(attrs, :title) || "")

    case check(state, :open_issue, title) do
      :ok ->
        issue_attrs =
          %{title: title, body: get(attrs, :body) || ""}
          |> maybe_labels(get(attrs, :labels))

        state
        |> ops_result(actor, :open_issue, [state.owner, state.repo, issue_attrs])
        |> reply(state)

      refusal ->
        reply(refusal, state)
    end
  end

  def handle_call({:write, actor, {:comment, number, body}}, _from, state) do
    state
    |> ops_result(actor, :comment, [state.owner, state.repo, number, body])
    |> reply(state)
  end

  def handle_call({:write, actor, {:ready_pr, number}}, _from, state) do
    state |> ops_result(actor, :ready_pr, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:write, actor, {:merge_pr, number}}, _from, state) do
    with :ok <- check(state, :merge_pr, number),
         :ok <- review_floor(state, number),
         {:ok, preferred} <- configured_merge_method(state) do
      state
      |> ops_result(actor, :merge_pr, [state.owner, state.repo, number, preferred])
      |> reply(state)
    else
      refusal -> reply(refusal, state)
    end
  end

  def handle_call(
        {:write, actor, {:merge_pr_at_head, number, head_sha, merge_method}},
        _from,
        state
      ) do
    with :ok <- pinned_merge_method(state, number, merge_method),
         :ok <- review_floor(state, number) do
      args = [state.owner, state.repo, number, head_sha, merge_method]
      state |> ops_result(actor, :merge_pr_at_head, args) |> reply(state)
    else
      refusal -> reply(refusal, state)
    end
  end

  def handle_call({:list_issues, opts}, _from, state) do
    read_op(:list_issues, [state.owner, state.repo, opts]) |> reply(state)
  end

  def handle_call({:view_issue, number}, _from, state) do
    read_op(:view_issue, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:list_prs, opts}, _from, state) do
    read_op(:list_prs, [state.owner, state.repo, opts]) |> reply(state)
  end

  def handle_call({:view_pr, number}, _from, state) do
    read_op(:view_pr, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:pr_checks, number}, _from, state) do
    read_op(:pr_checks, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:job_log_tail, job_id}, _from, state) do
    read_op(:job_log_tail, [state.owner, state.repo, job_id]) |> reply(state)
  end

  def handle_call({:pr_diff, number}, _from, state) do
    read_op(:pr_diff, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:review_snapshot, number}, _from, state) do
    case configured_merge_method(state) do
      {:ok, preferred} ->
        read_repo_op(state, :review_snapshot, [state.owner, state.repo, number, preferred])
        |> reply(state)

      refusal ->
        reply(refusal, state)
    end
  end

  # The workflow's review stage (#86) is mechanical law regardless of who
  # merges, latest-wins on the review timeline: an approving review or ok
  # "review:" marker opens the door; a "review: needs-human" marker
  # POSITIVELY blocks until a later review outranks it; nothing at all
  # blocks too (review always happens, even just lgtm). Each workflow
  # transition is one verb call -- this is the reviewed -> merged guard.
  defp review_floor(state, number) do
    case ops().review_state(state.owner, state.repo, number) do
      {:reviewed, _note} ->
        :ok

      {:needs_human, note} ->
        {:error,
         "workflow review: a reviewer flagged PR ##{number} on #{state.name} " <>
           "for a human (#{note}) -- only a later human review clears this"}

      :unreviewed ->
        {:error,
         "workflow review: PR ##{number} on #{state.name} has no review yet -- " <>
           "every merge is preceded by a review (an approving review or a " <>
           "\"review:\" comment), even just lgtm"}

      {:error, reason} ->
        {:error, "github: #{inspect(reason)}"}
    end
  end

  defp reply(result, state), do: {:reply, result, state}

  # MCP params arrive atom-keyed, direct callers may pass strings
  defp get(attrs, key), do: attrs[key] || attrs[to_string(key)]

  defp maybe_labels(attrs, labels) when is_list(labels) and labels != [],
    do: Map.put(attrs, :labels, labels)

  defp maybe_labels(attrs, _none), do: attrs

  # An opening verb learns its number from the RESULT; every other verb was
  # given one. Both are best-effort: a missing number is recorded as nil
  # rather than guessed at.
  defp verb_number(args, data) do
    from_data(data) || Enum.find(args, &is_integer/1)
  end

  defp from_data(%{} = data), do: data[:number] || data["number"]
  defp from_data(_other), do: nil

  defp ops_result(state, actor, verb, args) do
    case apply(ops(), verb, args) do
      {:ok, data} ->
        Custode.Feed.record(
          %{
            event: "repo_verb",
            agent: actor.id,
            # Structured, not just prose in the summary: without the verb, the
            # repo and the number as fields, nothing can later ask "which PRs did
            # this agent open, and did they land?" -- which is the measurement
            # #339's aggregate framing needs and custode cannot currently make.
            verb: to_string(verb),
            repo: state.name,
            number: verb_number(args, data),
            summary: "#{verb} on #{state.name}: ok"
          }
          |> put_merge_method(data)
        )

        {:ok, data}

      {:error, reason} ->
        repo_error(state, reason)
    end
  end

  # A merge verb's result names the method the repository allowed; record it so
  # "how did this land" is a field, not something read back off GitHub.
  defp put_merge_method(entry, %{"merge_method" => method}) when not is_nil(method),
    do: Map.put(entry, :merge_method, method)

  defp put_merge_method(entry, _data), do: entry

  # Reads take the same ops seam but no feed record (see the read-verbs note).
  defp read_op(verb, args) do
    case apply(ops(), verb, args) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "github: #{inspect(reason)}"}
    end
  end

  # Repository capability failures are policy evidence even when discovered
  # while building a read-only review snapshot. Preserve that typed refusal so
  # the reconciler does not reduce it to a generic GitHub error or a silent
  # "not merge ready" result.
  defp read_repo_op(state, verb, args) do
    case apply(ops(), verb, args) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> repo_error(state, reason)
    end
  end

  defp repo_error(state, :no_allowed_merge_method) do
    {:error,
     "policy merge_method: #{state.name} allows no supported merge method " <>
       "(merge, squash, rebase); nothing was merged"}
  end

  defp repo_error(state, {:merge_method_not_allowed, method}) do
    {:error,
     "policy merge_method: #{state.name} does not allow the #{method} merge method; " <>
       "nothing was merged"}
  end

  defp repo_error(_state, reason), do: {:error, "github: #{inspect(reason)}"}

  # ---------------------------------------------------------------------------
  # policy checks (the mechanical third of #50)
  # ---------------------------------------------------------------------------

  defp check(state, verb, subject) do
    policies = state |> routine() |> policies()
    ids = MapSet.new(policies, & &1.id)

    cond do
      verb == :merge_pr and merge_manual?(policies) ->
        {:error,
         "policy merge: humans merge PR ##{subject} on #{state.name}; ask through a gate instead"}

      verb in [:open_pr, :open_issue] and MapSet.member?(ids, :conventional_commits) and
          not conventional?(subject) ->
        {:error,
         "policy conventional_commits: title #{inspect(subject)} must start with " <>
           "feat:/fix:/docs:/test:/chore:/refactor:/perf:/ci:/build: (scope and ! allowed)"}

      true ->
        :ok
    end
  end

  defp merge_manual?(policies) do
    Enum.any?(policies, &(&1.id == :merge and &1.value == :manual))
  end

  # A repo-scoped :merge_method policy (#674) names the method merges on this
  # repository use; nil leaves the choice to GitHub's allow_* flag order.
  defp configured_merge_method(state) do
    case Custode.Policy.merge_method(state.name) do
      nil ->
        {:ok, nil}

      {:ok, method} ->
        {:ok, method}

      {:error, {:invalid_merge_method, value}} ->
        {:error,
         "policy merge_method: #{inspect(value)} configured for #{state.name} is not one of " <>
           "merge, squash, rebase"}
    end
  end

  # A merge Gate that pinned no supported method has nothing to send (#674).
  defp pinned_merge_method(_state, _number, method) when method in ~w(merge squash rebase),
    do: :ok

  defp pinned_merge_method(state, number, method) do
    {:error,
     "policy merge_method: the merge Gate for PR ##{number} on #{state.name} pins " <>
       "#{inspect(method)}, not one of merge, squash, rebase; nothing was merged"}
  end

  @conventional ~r/^(feat|fix|docs|test|chore|refactor|perf|ci|build)(\(.+\))?!?: .+/

  defp conventional?(title), do: Regex.match?(@conventional, title)

  defp routine(state), do: Custode.Routine.get(state.routine_id)

  defp policies(nil), do: []
  defp policies(routine), do: Custode.Policy.for_routine(routine)

  defp ops, do: Application.get_env(:custode, :repo_ops, Custode.Repository.Ops)
end

defmodule Custode.Repository.OpsBehaviour do
  @moduledoc """
  The contract behind the `:repo_ops` seam (#92): every GitHub read and
  write verb the Repository server dispatches. Fakes implement this so a
  drifted fake fails at compile time instead of mid-test.
  """

  @type owner :: String.t()
  @type repo :: String.t()
  @type result :: {:ok, term()} | {:error, term()}

  @callback open_pr(owner, repo, map()) :: result
  @callback open_issue(owner, repo, map()) :: result
  @callback comment(owner, repo, pos_integer(), String.t()) :: result
  @callback ready_pr(owner, repo, pos_integer()) :: result
  @callback merge_pr(owner, repo, pos_integer(), merge_method :: String.t() | nil) :: result
  @callback merge_pr_at_head(
              owner,
              repo,
              pos_integer(),
              head_sha :: String.t(),
              merge_method :: String.t()
            ) :: result
  @callback list_issues(owner, repo, keyword() | map()) :: result
  @callback view_issue(owner, repo, pos_integer()) :: result
  @callback list_prs(owner, repo, keyword() | map()) :: result
  @callback view_pr(owner, repo, pos_integer()) :: result
  @callback pr_checks(owner, repo, pos_integer()) :: result
  @callback job_log_tail(owner, repo, pos_integer()) :: result
  @callback pr_diff(owner, repo, pos_integer()) :: result
  @callback review_snapshot(owner, repo, pos_integer(), merge_method :: String.t() | nil) ::
              result
  @callback review_state(owner, repo, pos_integer()) :: result
end

defmodule Custode.Repository.Ops do
  @moduledoc "The real GitHub reads and writes behind the verbs (gh_ex, operator token)."

  @behaviour Custode.Repository.OpsBehaviour

  def open_pr(owner, repo, attrs) do
    with {:ok, client} <- client() do
      unwrap(GhEx.PullRequests.create(client, owner, repo, attrs))
    end
  end

  def open_issue(owner, repo, attrs) do
    with {:ok, client} <- client() do
      unwrap(GhEx.Issues.create(client, owner, repo, attrs))
    end
  end

  def comment(owner, repo, number, body) do
    with {:ok, client} <- client() do
      unwrap(GhEx.Issues.create_comment(client, owner, repo, number, body))
    end
  end

  # GitHub's REST update endpoint silently IGNORES the draft field (it
  # returned 200 while #937 stayed draft); draft -> ready is GraphQL-only.
  @ready_mutation """
  mutation($id: ID!) {
    markPullRequestReadyForReview(input: {pullRequestId: $id}) {
      pullRequest { number isDraft }
    }
  }
  """

  def ready_pr(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, pr} <- unwrap(GhEx.PullRequests.get(client, owner, repo, number)),
         {:ok, data, _meta} <- GhEx.GraphQL.query(client, @ready_mutation, id: pr["node_id"]) do
      case get_in(data, ["markPullRequestReadyForReview", "pullRequest"]) do
        %{"isDraft" => false} = ready -> {:ok, ready}
        other -> {:error, {:not_marked_ready, other}}
      end
    end
  end

  # A repository that disables merge commits rejects a bare merge call with
  # 405, so the method is chosen from the repository's allowed methods (#674).
  @merge_methods [
    {"allow_merge_commit", "merge"},
    {"allow_squash_merge", "squash"},
    {"allow_rebase_merge", "rebase"}
  ]

  @doc """
  Picks the merge method for a repository from the `allow_*` flags on its
  GitHub representation (string keys).

  `preferred` is the method a served repository's `:merge_method` policy
  names (`Custode.Policy.merge_method/1`), or nil. A preferred method wins
  over the flag order but must still be allowed: when the flags are visible
  and it is not, the result is `{:error, {:merge_method_not_allowed, method}}`
  rather than a silent fallback. Without a preference the order is merge
  commit, then squash, then rebase.

  When none of the flags are present the token cannot see them, so this
  returns the preferred method, or `"merge"`, the method used before the
  flags were consulted. When they are present and all false there is no
  method to use.
  """
  def merge_method(repository, preferred \\ nil)

  def merge_method(repository, preferred) when is_map(repository) do
    cond do
      flags_hidden?(repository) -> {:ok, preferred || "merge"}
      is_nil(preferred) -> first_allowed_merge_method(repository)
      merge_method_allowed?(repository, preferred) -> {:ok, preferred}
      true -> {:error, {:merge_method_not_allowed, preferred}}
    end
  end

  defp flags_hidden?(repository),
    do: Enum.all?(@merge_methods, fn {key, _method} -> is_nil(repository[key]) end)

  defp merge_method_allowed?(repository, method),
    do: Enum.any?(@merge_methods, fn {key, m} -> m == method and repository[key] == true end)

  defp first_allowed_merge_method(repository) do
    case Enum.find(@merge_methods, fn {key, _method} -> repository[key] == true end) do
      {_key, method} -> {:ok, method}
      nil -> {:error, :no_allowed_merge_method}
    end
  end

  def merge_pr(owner, repo, number, preferred) do
    with {:ok, client} <- client(),
         {:ok, repository} <- unwrap(GhEx.Repositories.get(client, owner, repo)),
         {:ok, method} <- merge_method(repository, preferred) do
      send_merge(client, owner, repo, number, %{merge_method: method})
    end
  end

  @doc """
  Merges at `head_sha` with exactly `method`, the method a merge Gate pinned
  (#674). The repository is re-read immediately before the request, and a
  method it no longer allows is refused without a merge request; nothing is
  reselected.
  """
  def merge_pr_at_head(owner, repo, number, head_sha, method) do
    with {:ok, client} <- client(),
         {:ok, repository} <- unwrap(GhEx.Repositories.get(client, owner, repo)),
         {:ok, ^method} <- merge_method(repository, method) do
      send_merge(client, owner, repo, number, %{merge_method: method, sha: head_sha})
    end
  end

  defp send_merge(client, owner, repo, number, params) do
    client
    |> GhEx.PullRequests.merge(owner, repo, number, params)
    |> unwrap()
    |> tag_merge_method(params.merge_method)
  end

  defp tag_merge_method({:ok, %{} = result}, method),
    do: {:ok, Map.put(result, "merge_method", method)}

  defp tag_merge_method(other, _method), do: other

  # ---------------------------------------------------------------------------
  # reads (issue #129): shaped down to what a sweep needs, not the raw payload
  # ---------------------------------------------------------------------------

  def list_issues(owner, repo, opts) do
    params = [state: state_param(opts), sort: "created", direction: "asc"]

    with {:ok, client} <- client(),
         {:ok, issues} <- unwrap(GhEx.Issues.list(client, owner, repo, params: params)) do
      # GitHub's issues endpoint returns PRs too; drop them (they carry a
      # "pull_request" key). PRs have their own verb.
      {:ok, issues |> Enum.reject(&Map.has_key?(&1, "pull_request")) |> Enum.map(&issue_row/1)}
    end
  end

  def view_issue(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, issue} <- unwrap(GhEx.Issues.get(client, owner, repo, number)),
         {:ok, comments} <- unwrap(GhEx.Issues.list_comments(client, owner, repo, number)) do
      {:ok,
       Map.put(issue_row(issue), :body, issue["body"])
       |> Map.put(:comments, comment_rows(comments))}
    end
  end

  def list_prs(owner, repo, opts) do
    params = [state: state_param(opts), sort: "created", direction: "asc"]

    with {:ok, client} <- client(),
         {:ok, prs} <- unwrap(GhEx.PullRequests.list(client, owner, repo, params: params)) do
      {:ok, Enum.map(prs, &pr_row/1)}
    end
  end

  def view_pr(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, pr} <- unwrap(GhEx.PullRequests.get(client, owner, repo, number)) do
      {:ok, pr_row(pr) |> Map.put(:body, pr["body"])}
    end
  end

  def pr_checks(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, pr} <- unwrap(GhEx.PullRequests.get(client, owner, repo, number)),
         sha = get_in(pr, ["head", "sha"]),
         {:ok, result} <- unwrap(GhEx.Checks.list_for_ref(client, owner, repo, sha)) do
      {:ok, %{sha: sha, checks: Enum.map(result["check_runs"] || [], &check_row/1)}}
    end
  end

  def job_log_tail(owner, repo, job_id) do
    with {:ok, client} <- client(),
         {:ok, log} <- unwrap(GhEx.Actions.download_job_logs(client, owner, repo, job_id)) do
      {:ok, failure_tail(log)}
    end
  end

  @doc false
  def failure_tail(log) when is_binary(log) do
    log
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.take(-12)
    |> Enum.join("\n")
    |> String.slice(-8_000, 8_000)
  end

  def pr_diff(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, files} <- unwrap(GhEx.PullRequests.list_files(client, owner, repo, number)) do
      {:ok, %{files: Enum.map(files, &file_row/1)}}
    end
  end

  def review_snapshot(owner, repo, number, preferred) do
    with {:ok, client} <- client(),
         {:ok, pr} <- unwrap(GhEx.PullRequests.get(client, owner, repo, number)),
         {:ok, reviews} <- unwrap(GhEx.PullRequests.list_reviews(client, owner, repo, number)),
         {:ok, comments} <- unwrap(GhEx.Issues.list_comments(client, owner, repo, number)),
         {:ok, repository} <- unwrap(GhEx.Repositories.get(client, owner, repo)),
         {:ok, merge_method} <- merge_method(repository, preferred),
         sha = get_in(pr, ["head", "sha"]),
         {:ok, result} <- unwrap(GhEx.Checks.list_for_ref(client, owner, repo, sha)) do
      {:ok,
       %{
         pull_request: pr_row(pr) |> Map.put(:body, pr["body"]),
         reviews: Enum.map(reviews, &review_row/1),
         comments: comment_rows(comments),
         checks: Enum.map(result["check_runs"] || [], &check_row/1),
         merge_method: merge_method
       }}
    end
  end

  defp state_param(opts), do: opts[:state] || opts["state"] || "open"

  defp issue_row(issue) do
    %{
      number: issue["number"],
      title: issue["title"],
      state: issue["state"],
      labels: for(l <- issue["labels"] || [], do: l["name"]),
      updated_at: issue["updated_at"],
      url: issue["html_url"]
    }
  end

  defp pr_row(pr) do
    %{
      number: pr["number"],
      title: pr["title"],
      state: pr["state"],
      draft: pr["draft"],
      base: get_in(pr, ["base", "ref"]),
      base_sha: get_in(pr, ["base", "sha"]),
      head: get_in(pr, ["head", "ref"]),
      head_sha: get_in(pr, ["head", "sha"]),
      mergeable: pr["mergeable"],
      mergeable_state: pr["mergeable_state"],
      merged: pr["merged"],
      merged_at: pr["merged_at"],
      merge_commit_sha: pr["merge_commit_sha"],
      updated_at: pr["updated_at"],
      url: pr["html_url"]
    }
  end

  defp review_row(review) do
    %{
      id: review["id"],
      author: get_in(review, ["user", "login"]),
      state: review["state"],
      body: review["body"],
      commit_id: review["commit_id"],
      submitted_at: review["submitted_at"]
    }
  end

  defp comment_rows(comments) do
    for c <- comments do
      %{
        id: c["id"],
        author: get_in(c, ["user", "login"]),
        body: c["body"],
        created_at: c["created_at"],
        updated_at: c["updated_at"]
      }
    end
  end

  defp check_row(run) do
    %{
      id: run["id"],
      name: run["name"],
      status: run["status"],
      conclusion: run["conclusion"],
      url: run["html_url"],
      started_at: run["started_at"],
      completed_at: run["completed_at"]
    }
  end

  defp file_row(file) do
    %{
      filename: file["filename"],
      # set on a rename; a move out of a sensitive directory still touches it
      previous_filename: file["previous_filename"],
      status: file["status"],
      additions: file["additions"],
      deletions: file["deletions"],
      patch: file["patch"]
    }
  end

  @doc """
  The PR's review state, latest-wins across formal reviews and "review:"
  marker comments: `{:reviewed, note}` | `{:needs_human, note}` |
  `:unreviewed` | `{:error, reason}`.
  """
  def review_state(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, reviews} <- unwrap(GhEx.PullRequests.list_reviews(client, owner, repo, number)),
         {:ok, comments} <- unwrap(GhEx.Issues.list_comments(client, owner, repo, number)) do
      review_events = Enum.flat_map(reviews, &review_event/1)
      marker_events = Enum.flat_map(comments, &marker_event/1)

      case (review_events ++ marker_events) |> Enum.sort_by(&elem(&1, 0)) |> List.last() do
        nil -> :unreviewed
        {_at, verdict, note} -> {verdict, note}
      end
    end
  end

  defp review_event(%{"state" => "APPROVED"} = review),
    do: [{to_string(review["submitted_at"]), :reviewed, "approving review"}]

  defp review_event(_review), do: []

  defp marker_event(comment) do
    body = to_string(comment["body"])
    at = to_string(comment["created_at"])

    cond do
      body |> String.downcase() |> String.starts_with?("review: needs-human") ->
        [{at, :needs_human, String.slice(body, 0, 200)}]

      body |> String.downcase() |> String.starts_with?("review:") ->
        [{at, :reviewed, String.slice(body, 0, 120)}]

      true ->
        []
    end
  end

  # gh_ex returns {:ok, data, meta} | {:error, exception} for every call site
  # above; the {:ok, data} / {:error, reason, meta} clauses this used to carry
  # were unreachable, which is what dialyzer surfaced (#92).
  defp unwrap({:ok, data, _meta}), do: {:ok, data}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp client do
    case token() do
      {:ok, token} -> {:ok, GhEx.new(auth: {:token, token}, req_options: req_options())}
      error -> error
    end
  end

  # Test seam: a test installs a Req.Test plug here to see the requests sent to
  # GitHub. It is not set in any config file.
  defp req_options, do: Application.get_env(:custode, :github_req_options, [])

  defp token do
    case System.get_env("GITHUB_TOKEN") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _unset ->
        case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
          {out, 0} -> {:ok, String.trim(out)}
          {out, _code} -> {:error, {:no_token, String.slice(out, 0, 100)}}
        end
    end
  end
end
