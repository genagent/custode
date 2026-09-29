defmodule Custode.MCP.Scope do
  @moduledoc """
  Runtime ownership checks for caller-scoped MCP operations.

  Client allowlists keep routine prompts small, but authenticated callers can
  still invoke an advertised tool directly. This module binds filesystem and
  repository-local effects to the identity attached to that request.
  """

  alias Custode.{AgentHandoff, MCP, OwnedCheckout, Repository}
  alias Custode.Gates.Class

  @type job_paths :: %{workspace: String.t() | nil, report_inbox: String.t()}

  @doc """
  Resolve and authorize a one-shot job's execution and reporting paths.

  Operators may use any existing directory. A routine runs in its configured
  working directory or its deterministic owned checkout and reports only to
  its notebook inbox. An omitted routine workspace defaults to its configured
  working directory.
  """
  @spec authorize_job(Anubis.Server.Frame.t(), String.t() | nil, String.t(), boolean()) ::
          {:ok, job_paths()} | {:error, String.t()}
  def authorize_job(frame, workspace, report_inbox, elevated) do
    caller = MCP.caller(frame)

    with :ok <- authorize_elevation(caller, elevated) do
      authorize_job_paths(caller, workspace, report_inbox)
    end
  end

  @doc """
  Resolve and authorize a one-shot job's turn cap (#673).

  Omitted keeps the configured default (`:run_job_max_turns`, 15). Any named
  value must be a positive integer no greater than the hard ceiling
  (`:run_job_max_turns_ceiling`), whoever asks. Lowering the cap is always
  allowed. Raising it above the default is the operator's call, or a
  routine's while an approved action of a shell class is in flight, the same
  `Custode.Gates.Class.shell?/1` rule that gates elevated jobs. That approval
  must also name the cap it sized: its detail carries one stable
  `max_turns=<N>` marker, and the request must be exactly `N`. The resolved
  cap is then the number the operator read and approved, not a ceiling under
  it, and neither an unapproved sweep nor an unrelated approval (a comment,
  a ready_pr) can buy a longer job.

  Both configured bounds are checked first: a non-positive or non-integer
  value, or a default above the ceiling, is an error for every request,
  including an omitted one, so a bad config never inserts a job.
  """
  @spec authorize_job_turns(Anubis.Server.Frame.t(), term()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  def authorize_job_turns(frame, requested) do
    with {:ok, default, ceiling} <- job_turns_bounds() do
      cond do
        is_nil(requested) ->
          {:ok, default}

        not is_integer(requested) or requested < 1 ->
          {:error, "max_turns: must be a positive integer, got #{inspect(requested)}"}

        requested > ceiling ->
          {:error, "max_turns: #{requested} exceeds the hard ceiling of #{ceiling}"}

        requested <= default ->
          {:ok, requested}

        true ->
          authorize_raised_turns(MCP.caller(frame), requested, default)
      end
    end
  end

  @doc "The turn cap a one-shot job gets when the caller names none, as configured."
  @spec job_turns_default() :: term()
  def job_turns_default, do: Application.get_env(:custode, :run_job_max_turns, 15)

  @doc "The turn cap no one-shot job may exceed, whoever asks, as configured."
  @spec job_turns_ceiling() :: term()
  def job_turns_ceiling, do: Application.get_env(:custode, :run_job_max_turns_ceiling, 150)

  @doc """
  The configured default and ceiling, validated: both positive integers and
  the default no greater than the ceiling.
  """
  @spec job_turns_bounds() :: {:ok, pos_integer(), pos_integer()} | {:error, String.t()}
  def job_turns_bounds do
    default = job_turns_default()
    ceiling = job_turns_ceiling()

    cond do
      not positive_integer?(default) ->
        {:error,
         "max_turns: configured run_job_max_turns must be a positive integer, " <>
           "got #{inspect(default)}"}

      not positive_integer?(ceiling) ->
        {:error,
         "max_turns: configured run_job_max_turns_ceiling must be a positive integer, " <>
           "got #{inspect(ceiling)}"}

      default > ceiling ->
        {:error,
         "max_turns: configured run_job_max_turns #{default} exceeds " <>
           "run_job_max_turns_ceiling #{ceiling}"}

      true ->
        {:ok, default, ceiling}
    end
  end

  @doc """
  The turn cap an approved action's detail names through its one stable
  `max_turns=<N>` marker. `:missing` when it names none (or only zero),
  `:ambiguous` when it names more than one value.
  """
  @spec approved_turn_cap(String.t() | nil) :: {:ok, pos_integer()} | :missing | :ambiguous
  def approved_turn_cap(detail) when is_binary(detail) do
    caps =
      ~r/(?<![\w-])max_turns=(\d+)(?!\w)/
      |> Regex.scan(detail, capture: :all_but_first)
      |> Enum.map(fn [n] -> String.to_integer(n) end)
      |> Enum.reject(&(&1 == 0))
      |> Enum.uniq()

    case caps do
      [] -> :missing
      [cap] -> {:ok, cap}
      _many -> :ambiguous
    end
  end

  def approved_turn_cap(_detail), do: :missing

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp authorize_raised_turns(%{kind: :operator}, requested, _default), do: {:ok, requested}

  defp authorize_raised_turns(%{kind: :routine, id: id}, requested, default) do
    # the same rule as elevation: only a shell-class approval (implement,
    # pr_maintain, or an unbounded other/undeclared class) sizes a long job,
    # and it must name the cap it sized
    case Custode.Gates.active_grant(id) do
      %{class: class, gate_id: gate_id} = grant ->
        if Class.shell?(class) do
          within_approved_cap(grant, requested, default)
        else
          {:error,
           "gate grant: max_turns #{requested} is above the default of #{default} " <>
             "and outside gate #{gate_id} (class #{class}); " <>
             "raise request_permission for shell work first"}
        end

      nil ->
        {:error,
         "gate grant: max_turns #{requested} is above the default of #{default} " <>
           "with no approved action in flight; raise request_permission first"}
    end
  end

  defp authorize_raised_turns(%{id: id}, requested, default) do
    {:error,
     "identity: #{id} may not raise max_turns to #{requested} above the default of #{default}"}
  end

  defp within_approved_cap(%{gate_id: gate_id, detail: detail}, requested, default) do
    case approved_turn_cap(detail) do
      {:ok, ^requested} ->
        {:ok, requested}

      {:ok, cap} ->
        {:error,
         "gate grant: max_turns #{requested} is not the max_turns=#{cap} " <>
           "that gate #{gate_id} approved; request exactly #{cap}"}

      :missing ->
        {:error,
         "gate grant: max_turns #{requested} is above the default of #{default} " <>
           "but gate #{gate_id} names no max_turns=<N>; " <>
           "name the cap in the request_permission action"}

      :ambiguous ->
        {:error,
         "gate grant: gate #{gate_id} names more than one max_turns=<N>, " <>
           "so max_turns #{requested} matches no single approved cap"}
    end
  end

  @doc """
  Authorize a mutable fact tied to one served repository.

  Operators may act on any served repository. A routine may mutate local facts
  only for the repository in its current roster entry.
  """
  @spec authorize_repo_fact(Anubis.Server.Frame.t(), String.t()) ::
          :ok | {:error, String.t()}
  def authorize_repo_fact(frame, repo) do
    caller = MCP.caller(frame)

    with :ok <- served(repo) do
      authorize_repo_caller(caller, repo)
    end
  end

  defp authorize_repo_caller(%{kind: :operator}, _repo), do: :ok

  defp authorize_repo_caller(%{kind: :routine, id: id}, repo) do
    case AgentHandoff.authorization_routine(id) do
      {:ok, routine} -> authorize_routine_repo(routine, id, repo)
      {:error, :handoff_pending} -> {:error, handoff_error(id)}
      {:error, _reason} -> authorize_routine_repo(nil, id, repo)
    end
  end

  defp authorize_repo_caller(%{kind: :sub_agent, id: id}, _repo),
    do: {:error, "identity: temporary agent #{id} may not change repository facts"}

  defp authorize_routine_repo(%{repo: repo}, _id, repo), do: :ok

  defp authorize_routine_repo(%{repo: nil}, id, _repo),
    do: {:error, "identity: routine #{id} has no configured repository"}

  defp authorize_routine_repo(%{repo: owned}, id, repo),
    do: {:error, "identity: routine #{id} owns repository #{owned}, not #{repo}"}

  defp authorize_routine_repo(nil, id, _repo),
    do: {:error, "identity: routine #{id} is not in the current roster"}

  @doc "Authorize a local fact owned by an identity, with an operator override."
  @spec authorize_owner(Anubis.Server.Frame.t(), String.t()) :: :ok | {:error, String.t()}
  def authorize_owner(frame, owner_id) do
    case MCP.caller(frame) do
      %{kind: :operator} ->
        :ok

      %{kind: :routine, id: ^owner_id} ->
        :ok

      %{kind: :sub_agent, id: caller_id} ->
        {:error, "identity: temporary agent #{caller_id} may not change repository facts"}

      %{id: caller_id} ->
        {:error, "identity: #{caller_id} may not change a record owned by #{owner_id}"}
    end
  end

  defp authorize_elevation(%{kind: :operator}, _elevated), do: :ok
  defp authorize_elevation(_caller, false), do: :ok

  defp authorize_elevation(%{kind: :routine, id: id}, true) do
    case Custode.Gates.active_grant(id) do
      %{class: class, gate_id: gate_id} ->
        if Class.shell?(class) do
          :ok
        else
          {:error,
           "gate grant: elevated job is outside gate #{gate_id} (class #{class}); " <>
             "raise request_permission for shell work first"}
        end

      nil ->
        {:error,
         "gate grant: elevated job with no approved action in flight; " <>
           "raise request_permission first"}
    end
  end

  defp authorize_elevation(%{kind: :sub_agent, id: id}, true),
    do: {:error, "identity: temporary agent #{id} may not run elevated jobs"}

  defp authorize_job_paths(%{kind: :operator}, workspace, report_inbox) do
    {:ok,
     %{
       workspace: expand_optional(workspace),
       report_inbox: Path.expand(report_inbox)
     }}
  end

  defp authorize_job_paths(%{kind: :routine, id: id}, workspace, report_inbox) do
    case AgentHandoff.authorization_routine(id) do
      {:error, :handoff_pending} ->
        {:error, handoff_error(id)}

      {:error, _reason} ->
        {:error, "identity: routine #{id} is not in the current roster"}

      {:ok, routine} ->
        workspace = workspace || routine.working_dir
        {:ok, owned_checkout} = OwnedCheckout.path(id)

        with {:ok, workspace} <-
               authorize_path(workspace, [routine.working_dir, owned_checkout], "workspace", id),
             {:ok, report_inbox} <-
               authorize_path(
                 report_inbox,
                 [Path.join(routine.workspace, "inbox")],
                 "report_inbox",
                 id
               ) do
          {:ok, %{workspace: workspace, report_inbox: report_inbox}}
        end
    end
  end

  defp authorize_job_paths(%{kind: :sub_agent, id: id}, _workspace, _report_inbox),
    do: {:error, "identity: temporary agent #{id} may not run jobs"}

  defp handoff_error(id),
    do: "identity: routine #{id} is changing configuration; retry after its handoff completes"

  defp authorize_path(path, roots, label, caller_id) do
    expanded = Path.expand(path)
    expanded_roots = Enum.map(roots, &Path.expand/1)

    if Enum.any?(expanded_roots, &inside?(expanded, &1)) do
      authorize_physical_path(expanded, expanded_roots, label, caller_id)
    else
      {:error, "identity: routine #{caller_id} may not use #{label} #{expanded}"}
    end
  end

  # Existing symlinks must not turn a lexically contained path into a sibling
  # checkout. A missing directory is left to the handler's ordinary validation;
  # no job or filesystem write has happened at that point.
  defp authorize_physical_path(path, roots, label, caller_id) do
    if File.dir?(path) do
      physical_roots = Enum.flat_map(roots, &physical_root/1)
      authorize_physical_candidate(physical_path(path), physical_roots, path, label, caller_id)
    else
      {:ok, path}
    end
  end

  defp authorize_physical_candidate(
         {:ok, physical_path},
         physical_roots,
         _path,
         label,
         caller_id
       ) do
    if Enum.any?(physical_roots, &inside?(physical_path, &1)),
      do: {:ok, physical_path},
      else: {:error, "identity: routine #{caller_id} may not use #{label} #{physical_path}"}
  end

  defp authorize_physical_candidate({:error, _reason}, _roots, path, label, caller_id),
    do: {:error, "identity: routine #{caller_id} may not use #{label} #{path}"}

  defp physical_root(root) do
    if File.dir?(root) do
      case physical_path(root) do
        {:ok, path} -> [path]
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp physical_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_links([], 0)
  end

  defp resolve_links(_parts, _resolved, hops) when hops > 40, do: {:error, :too_many_links}

  defp resolve_links([], resolved, _hops), do: {:ok, Path.join(resolved)}

  defp resolve_links([part | rest], resolved, hops) do
    candidate = Path.join(resolved ++ [part])

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target
          |> Path.expand(Path.dirname(candidate))
          |> Path.split()
          |> Kernel.++(rest)
          |> resolve_links([], hops + 1)
        end

      {:ok, _stat} ->
        resolve_links(rest, resolved ++ [part], hops)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp served(repo) do
    if Repository.served?(repo),
      do: :ok,
      else: {:error, "repo #{repo} is not served (no routine is tied to it)"}
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp expand_optional(nil), do: nil
  defp expand_optional(path), do: Path.expand(path)
end
