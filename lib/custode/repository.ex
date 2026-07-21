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

  v1 verbs: `open_pr/2`, `comment/3`, `ready_pr/2`, `merge_pr/2`.
  Reads stay on `Custode.GitHub` (the dashboard panel fetcher/cache).
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

  @doc "Merge a PR. Refused wherever the merge policy is :manual."
  def merge_pr(name, number), do: call(name, {:merge_pr, number})

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
    title = to_string(attrs[:title] || attrs["title"] || "")

    case check(state, :open_pr, title) do
      :ok ->
        pr_attrs = %{
          title: title,
          head: attrs[:head] || attrs["head"],
          base: attrs[:base] || attrs["base"] || "main",
          body: attrs[:body] || attrs["body"] || "",
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
    case check(state, :merge_pr, number) do
      :ok -> state |> ops_result(:merge_pr, [state.owner, state.repo, number]) |> reply(state)
      refusal -> reply(refusal, state)
    end
  end

  defp reply(result, state), do: {:reply, result, state}

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
  @moduledoc "The real GitHub writes behind the verbs (gh_ex, operator token)."

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

  def ready_pr(owner, repo, number) do
    with {:ok, client} <- client() do
      unwrap(GhEx.PullRequests.update(client, owner, repo, number, %{draft: false}))
    end
  end

  def merge_pr(owner, repo, number) do
    with {:ok, client} <- client() do
      unwrap(GhEx.PullRequests.merge(client, owner, repo, number))
    end
  end

  defp unwrap({:ok, data, _meta}), do: {:ok, data}
  defp unwrap({:ok, data}), do: {:ok, data}
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap({:error, reason, _meta}), do: {:error, reason}

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
