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

  Write verbs: `open_pr/2`, `comment/3`, `ready_pr/2`, `merge_pr/2`.
  Read verbs (#129): `list_issues/2`, `view_issue/2`, `list_prs/2`,
  `view_pr/2`, `pr_checks/2`, `pr_diff/2` -- scoped GitHub reads through the
  bound server, replacing the unscoped `gh issue list` / `gh pr view` Bash
  grants. `Custode.GitHub` still owns the dashboard panel fetcher/cache.
  """

  use GenServer

  @registry Custode.Repository.Registry

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

  @doc "Is this repo served? (Only served repos can be written to at all.)"
  def served?(name), do: match?([{_pid, _value}], Registry.lookup(@registry, name))

  # ---------------------------------------------------------------------------
  # verbs
  # ---------------------------------------------------------------------------

  @doc """
  Open a PR. `attrs`: title, head, base (defaults "main"), body.
  Policy: conventional title enforced; draft forced when draft_pr_first
  binds (which it should).
  """
  def open_pr(name, attrs), do: call(name, {:open_pr, attrs})

  @doc "Comment on an issue or PR by number."
  def comment(name, number, body), do: call(name, {:comment, number, body})

  @doc "Mark a draft PR ready for review."
  def ready_pr(name, number), do: call(name, {:ready_pr, number})

  @doc "The issue's ready transition (#86): posts a `ready: <plan>` comment."
  def mark_issue_ready(name, number, plan),
    do: call(name, {:comment, number, "ready: " <> plan})

  @doc "The issue's blocked transition (#86): posts a `blocked: <reason>` comment."
  def mark_issue_blocked(name, number, reason),
    do: call(name, {:comment, number, "blocked: " <> reason})

  @doc """
  The review transition (#86): posts a `review:` marker the merge floor
  reads. `verdict` is "lgtm" (or any ok text) or "needs-human"; the body
  carries findings.
  """
  def review_pr(name, number, verdict, body) do
    prefix =
      case verdict do
        "needs-human" -> "review: needs-human -- "
        other -> "review: #{other} -- "
      end

    call(name, {:comment, number, prefix <> body})
  end

  @doc "Merge a PR. Refused wherever the merge policy is :manual."
  def merge_pr(name, number), do: call(name, {:merge_pr, number})

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

  @doc "View one issue: title, state, labels, body, and its comments."
  def view_issue(name, number), do: call(name, {:view_issue, number})

  @doc "List pull requests (defaults to open, oldest first). `opts`: `:state`."
  def list_prs(name, opts \\ %{}), do: call(name, {:list_prs, opts})

  @doc "View one PR: title, state, draft, base/head, body."
  def view_pr(name, number), do: call(name, {:view_pr, number})

  @doc "The check runs on a PR's head commit (name, status, conclusion)."
  def pr_checks(name, number), do: call(name, {:pr_checks, number})

  @doc "The changed files of a PR, each with its patch (the diff)."
  def pr_diff(name, number), do: call(name, {:pr_diff, number})

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
  def handle_call({:open_pr, attrs}, _from, state) do
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

        state |> ops_result(:open_pr, [state.owner, state.repo, pr_attrs]) |> reply(state)

      refusal ->
        reply(refusal, state)
    end
  end

  def handle_call({:comment, number, body}, _from, state) do
    state |> ops_result(:comment, [state.owner, state.repo, number, body]) |> reply(state)
  end

  def handle_call({:ready_pr, number}, _from, state) do
    state |> ops_result(:ready_pr, [state.owner, state.repo, number]) |> reply(state)
  end

  def handle_call({:merge_pr, number}, _from, state) do
    with :ok <- check(state, :merge_pr, number),
         :ok <- review_floor(state, number) do
      state |> ops_result(:merge_pr, [state.owner, state.repo, number]) |> reply(state)
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

  def handle_call({:pr_diff, number}, _from, state) do
    read_op(:pr_diff, [state.owner, state.repo, number]) |> reply(state)
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

  defp ops_result(state, verb, args) do
    case apply(ops(), verb, args) do
      {:ok, data} ->
        Custode.Feed.record(%{
          event: "repo_verb",
          agent: state.routine_id,
          summary: "#{verb} on #{state.name}: ok"
        })

        {:ok, data}

      {:error, reason} ->
        {:error, "github: #{inspect(reason)}"}
    end
  end

  # Reads take the same ops seam but no feed record (see the read-verbs note).
  defp read_op(verb, args) do
    case apply(ops(), verb, args) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "github: #{inspect(reason)}"}
    end
  end

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

      verb == :open_pr and MapSet.member?(ids, :conventional_commits) and
          not conventional?(subject) ->
        {:error,
         "policy conventional_commits: PR title #{inspect(subject)} must start with " <>
           "feat:/fix:/docs:/test:/chore:/refactor:/perf:/ci:/build: (scope and ! allowed)"}

      true ->
        :ok
    end
  end

  defp merge_manual?(policies) do
    Enum.any?(policies, &(&1.id == :merge and &1.value == :manual))
  end

  @conventional ~r/^(feat|fix|docs|test|chore|refactor|perf|ci|build)(\(.+\))?!?: .+/

  defp conventional?(title), do: Regex.match?(@conventional, title)

  defp routine(state), do: Custode.Routine.get(state.routine_id)

  defp policies(nil), do: []
  defp policies(routine), do: Custode.Policy.for_routine(routine)

  defp ops, do: Application.get_env(:custode, :repo_ops, Custode.Repository.Ops)
end

defmodule Custode.Repository.Ops do
  @moduledoc "The real GitHub reads and writes behind the verbs (gh_ex, operator token)."

  def open_pr(owner, repo, attrs) do
    with {:ok, client} <- client() do
      unwrap(GhEx.PullRequests.create(client, owner, repo, attrs))
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

  def merge_pr(owner, repo, number) do
    with {:ok, client} <- client() do
      unwrap(GhEx.PullRequests.merge(client, owner, repo, number))
    end
  end

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

  def pr_diff(owner, repo, number) do
    with {:ok, client} <- client(),
         {:ok, files} <- unwrap(GhEx.PullRequests.list_files(client, owner, repo, number)) do
      {:ok, %{files: Enum.map(files, &file_row/1)}}
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
      head: get_in(pr, ["head", "ref"]),
      updated_at: pr["updated_at"],
      url: pr["html_url"]
    }
  end

  defp comment_rows(comments) do
    for c <- comments, do: %{author: get_in(c, ["user", "login"]), body: c["body"]}
  end

  defp check_row(run) do
    %{name: run["name"], status: run["status"], conclusion: run["conclusion"]}
  end

  defp file_row(file) do
    %{
      filename: file["filename"],
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
      {:ok, token} -> {:ok, GhEx.new(auth: {:token, token})}
      error -> error
    end
  end

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
