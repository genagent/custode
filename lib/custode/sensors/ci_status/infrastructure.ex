defmodule Custode.Sensors.CiStatus.Infrastructure do
  @moduledoc """
  Durable, repository-scoped evidence that CI is blocked before jobs begin.

  Every successful CI sensor read replaces the repository's complete
  observation, including an empty observation that clears an older block.
  Duplicate sensors therefore cannot union stale positive evidence. A total
  overview fetch error never calls this module, so the last confirmed
  observation remains visible.

  Each affected item carries the exact commit ref that was classified. The
  attention gatherer only suppresses a red item while the cached overview
  still points at that ref, so a new commit cannot inherit an old exception.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Memory
  alias Custode.Repo
  alias Custode.Routine
  alias Custode.Sensors.CiStatus

  @scope "sensor:ci-infrastructure:"
  @key "ci_infrastructure"

  @type active :: %{
          repo: String.t(),
          notify: String.t(),
          sensor_id: String.t(),
          since: DateTime.t(),
          observed_at: DateTime.t(),
          prs: [pos_integer()],
          branches: [String.t()],
          pr_refs: %{pos_integer() => String.t()},
          branch_refs: %{String.t() => String.t()},
          max_seconds: non_neg_integer()
        }

  @doc false
  def replace(args, blocked, max_seconds) when is_map(args) and is_list(blocked) do
    replace(args, blocked, max_seconds, DateTime.utc_now())
  end

  @doc false
  def replace(args, blocked, max_seconds, observed_at)
      when is_map(args) and is_list(blocked) and is_struct(observed_at, DateTime) do
    sensor_id = Map.fetch!(args, "sensor_id")
    repo = Map.fetch!(args, "repo")
    notify = Map.fetch!(args, "notify")

    :global.trans({{__MODULE__, repo}, self()}, fn ->
      now = DateTime.utc_now()
      previous = previous(repo)

      if newer_than?(previous, observed_at) do
        :ok
      else
        {prs, branches} = current_items(blocked, previous, now)

        state = %{
          sensor_id: sensor_id,
          repo: repo,
          notify: notify,
          observed_at: observed_at,
          since: condition_since(previous, prs, branches, now),
          max_seconds: max_seconds,
          prs: prs,
          branches: branches
        }

        Memory.remember(scope(repo), @key, encode(state))
      end
    end)
  end

  @doc "Active infrastructure conditions, keyed and deduplicated by repo."
  @spec active() :: %{String.t() => active()}
  def active do
    configured = configured_repos()

    stored()
    |> Enum.flat_map(&configured_state(configured, &1))
    |> Map.new(fn state -> {state.repo, project(state)} end)
  end

  defp current_items(blocked, previous, now) do
    prior_prs = index(previous && previous.prs, &{&1.number, &1.ref})
    prior_branches = index(previous && previous.branches, &{&1.name, &1.ref})

    prs =
      blocked
      |> Enum.flat_map(fn
        %{kind: :pr, number: number, head_sha: ref}
        when is_integer(number) and number > 0 and is_binary(ref) and ref != "" ->
          [%{number: number, ref: ref}]

        _invalid ->
          []
      end)
      |> Enum.uniq_by(&{&1.number, &1.ref})
      |> Enum.map(fn item ->
        Map.put(item, :since, since(prior_prs, {item.number, item.ref}, now))
      end)
      |> Enum.sort_by(&{&1.number, &1.ref})

    branches =
      blocked
      |> Enum.flat_map(fn
        %{kind: :branch, name: name, oid: ref}
        when is_binary(name) and name != "" and is_binary(ref) and ref != "" ->
          [%{name: name, ref: ref}]

        _invalid ->
          []
      end)
      |> Enum.uniq_by(&{&1.name, &1.ref})
      |> Enum.map(fn item ->
        Map.put(item, :since, since(prior_branches, {item.name, item.ref}, now))
      end)
      |> Enum.sort_by(&{&1.name, &1.ref})

    {prs, branches}
  end

  defp condition_since(previous, prs, branches, now) do
    if active?(previous) and (prs != [] or branches != []),
      do: previous.since,
      else: now
  end

  defp newer_than?(nil, _observed_at), do: false

  defp newer_than?(previous, observed_at),
    do: DateTime.compare(previous.observed_at, observed_at) == :gt

  defp previous(repo) do
    case Memory.recall(scope(repo), @key) do
      {:ok, json} -> decode(json)
      :error -> nil
    end
  end

  defp index(nil, _key), do: %{}
  defp index(items, key), do: Map.new(items, &{key.(&1), &1.since})
  defp since(previous, key, now), do: Map.get(previous, key, now)
  defp active?(nil), do: false
  defp active?(state), do: state.prs != [] or state.branches != []
  defp scope(repo), do: @scope <> repo

  defp configured_repos do
    Routine.sensors()
    |> Enum.filter(&(&1.module == CiStatus))
    |> Enum.flat_map(fn sensor ->
      case sensor.args[:repo] || sensor.args["repo"] do
        repo when is_binary(repo) and repo != "" -> [{repo, sensor}]
        _invalid -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {repo, sensors} -> {repo, Enum.min_by(sensors, &{&1.id, &1.notify})} end)
  end

  defp stored do
    from(m in Memory.Entry,
      where: m.key == @key and like(m.agent_id, ^(@scope <> "%")),
      select: m.value
    )
    |> Repo.all()
    |> Enum.flat_map(fn json ->
      case decode(json) do
        nil -> []
        state -> [state]
      end
    end)
  end

  defp configured_state(configured, state) do
    case Map.get(configured, state.repo) do
      %{id: sensor_id, notify: notify} when state.prs != [] or state.branches != [] ->
        [%{state | sensor_id: sensor_id, notify: notify}]

      _removed_or_clear ->
        []
    end
  end

  defp project(state) do
    %{
      repo: state.repo,
      notify: state.notify,
      sensor_id: state.sensor_id,
      since: state.since,
      observed_at: state.observed_at,
      prs: Enum.map(state.prs, & &1.number),
      branches: Enum.map(state.branches, & &1.name),
      pr_refs: Map.new(state.prs, &{&1.number, &1.ref}),
      branch_refs: Map.new(state.branches, &{&1.name, &1.ref}),
      max_seconds: state.max_seconds
    }
  end

  defp encode(state) do
    Jason.encode!(%{
      "sensor_id" => state.sensor_id,
      "repo" => state.repo,
      "notify" => state.notify,
      "observed_at" => encode_time(state.observed_at),
      "since" => encode_time(state.since),
      "max_seconds" => state.max_seconds,
      "prs" =>
        Enum.map(state.prs, fn item ->
          %{"number" => item.number, "ref" => item.ref, "since" => encode_time(item.since)}
        end),
      "branches" =>
        Enum.map(state.branches, fn item ->
          %{"name" => item.name, "ref" => item.ref, "since" => encode_time(item.since)}
        end)
    })
  end

  defp decode(json) do
    with {:ok,
          %{
            "sensor_id" => sensor_id,
            "repo" => repo,
            "notify" => notify,
            "observed_at" => observed_at,
            "since" => since,
            "max_seconds" => max_seconds,
            "prs" => prs,
            "branches" => branches
          }} <- Jason.decode(json),
         true <- is_binary(sensor_id) and is_binary(repo) and is_binary(notify),
         true <- is_integer(max_seconds) and max_seconds >= 0,
         {:ok, parsed_observed_at} <- decode_time(observed_at),
         {:ok, parsed_since} <- decode_time(since),
         {:ok, parsed_prs} <- decode_prs(prs),
         {:ok, parsed_branches} <- decode_branches(branches) do
      %{
        sensor_id: sensor_id,
        repo: repo,
        notify: notify,
        observed_at: parsed_observed_at,
        since: parsed_since,
        max_seconds: max_seconds,
        prs: parsed_prs,
        branches: parsed_branches
      }
    else
      _malformed -> nil
    end
  end

  defp decode_prs(prs) when is_list(prs) do
    decode_items(prs, fn
      %{"number" => number, "ref" => ref, "since" => since}
      when is_integer(number) and number > 0 and is_binary(ref) and ref != "" ->
        with {:ok, parsed} <- decode_time(since),
             do: {:ok, %{number: number, ref: ref, since: parsed}}

      _invalid ->
        :error
    end)
  end

  defp decode_prs(_invalid), do: :error

  defp decode_branches(branches) when is_list(branches) do
    decode_items(branches, fn
      %{"name" => name, "ref" => ref, "since" => since}
      when is_binary(name) and name != "" and is_binary(ref) and ref != "" ->
        with {:ok, parsed} <- decode_time(since),
             do: {:ok, %{name: name, ref: ref, since: parsed}}

      _invalid ->
        :error
    end)
  end

  defp decode_branches(_invalid), do: :error

  defp decode_items(items, decoder) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, parsed} ->
      case decoder.(item) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  defp encode_time(at), do: DateTime.to_iso8601(at)

  defp decode_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp decode_time(_invalid), do: :error
end
