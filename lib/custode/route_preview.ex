defmodule Custode.RoutePreview do
  @moduledoc "Deterministic shadow routing over configured routines; never admission or execution."
  alias Custode.{AgentHandoff, Availability, Repo, Routine, SpendLedger}
  alias Custode.Operator.Authority

  defmodule Decision do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:request_id, :string, autogenerate: false}
    schema "route_decisions" do
      field(:fingerprint, :string)
      field(:actor_id, :string)
      field(:decision, :map)
    end
  end

  @classes ~w(implementation review research discussion)
  @phases ~w(plan execute verify)
  @keys ~w(request_id task_id input_revision class phase candidate_ids configured_route pin required_tools required_capabilities isolation context_refs context_provider limits)
  @default_policy %{
    version: "route-preview:v1",
    max_age_seconds: 900,
    interactive_reserve: 0.1,
    floors: %{"implementation" => 3, "review" => 2, "research" => 2, "discussion" => 1},
    triples: %{
      "claude/opus/high" => %{tier: 3, weight: 1.0, capabilities: []},
      "claude/opus/max" => %{tier: 3, weight: 1.0, capabilities: []},
      "claude/sonnet/medium" => %{tier: 2, weight: 1.0, capabilities: []},
      "claude/sonnet/high" => %{tier: 2, weight: 1.0, capabilities: []}
    }
  }

  @doc "Resolve and durably freeze one preview. Identical request retries return the original decision."
  def preview(actor, request, opts \\ []) do
    with :ok <- Authority.fleet_control(actor),
         :ok <- valid_request(request) do
      fingerprint = digest({actor, request})

      prepare_preview(actor, request, fingerprint, opts)
    end
  end

  defp prepare_preview(actor, request, fingerprint, opts) do
    case Repo.get(Decision, request["request_id"]) do
      %Decision{fingerprint: ^fingerprint, decision: decision} ->
        {:ok, decision}

      %Decision{} ->
        {:error, :idempotency_conflict}

      nil ->
        frozen = build_decision(actor, request, opts)

        Repo.transaction(fn -> load_or_record!(actor, request, fingerprint, frozen) end,
          mode: :immediate
        )
    end
  end

  defp load_or_record!(actor, request, fingerprint, frozen) do
    case Repo.get(Decision, request["request_id"]) do
      %Decision{fingerprint: ^fingerprint, decision: decision} ->
        decision

      %Decision{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        Repo.insert!(%Decision{
          request_id: request["request_id"],
          fingerprint: fingerprint,
          actor_id: Map.get(actor, :id, "operator"),
          decision: frozen
        })

        frozen
    end
  end

  @doc "Read a frozen shadow decision; it does not refresh observations or reserve capacity."
  def read(actor, request_id) do
    with :ok <- Authority.fleet_control(actor) do
      case Repo.get(Decision, request_id) do
        nil -> {:error, :unknown_decision}
        row -> {:ok, row.decision}
      end
    end
  end

  defp build_decision(actor, request, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = Application.get_env(:custode, :routing_preview_policy, @default_policy)
    candidates = Enum.map(request["candidate_ids"], &candidate(&1, request, policy, now))
    eligible = Enum.filter(candidates, &(&1.reasons == []))
    selected = choose(eligible, request)
    status = status(selected, candidates, request)

    decision =
      %{
        schema_version: "custode.route_preview.v1",
        request_id: request["request_id"],
        request: request,
        actor: actor,
        observed_at: DateTime.to_iso8601(now),
        policy_version: policy.version,
        policy_revision: digest(policy),
        policy: policy,
        status: status,
        selected: selected,
        alternatives: candidates,
        authority: "preview_only_current_grants_required_at_admission",
        capacity_reserved: false,
        execution_changed: false,
        promotion: "requires_20_natural_requests_and_separate_authorized_evaluation",
        evidence_class: "shadow_request_not_task_quality"
      }
      |> Jason.encode!()
      |> Jason.decode!()

    decision
  end

  defp candidate(id, request, policy, now) do
    with {:ok, authorization} <- AgentHandoff.authorization_routine(id),
         %{} = routine <- Routine.get(id),
         true <- authorization.execution_revision == Routine.execution_revision(routine) do
      configured_candidate(routine, request, policy, now)
    else
      _unavailable -> %{id: id, reasons: ["unknown_or_transitioning_candidate"], score: nil}
    end
  end

  defp configured_candidate(routine, request, policy, now) do
    id = routine.id
    contract = Routine.continuation_contract(routine)

    triple =
      Enum.join(
        [routine.provider, routine.model || "<default>", routine.effort || "<default>"],
        "/"
      )

    declared = policy.triples[triple]
    observation = observation(to_string(routine.provider), policy, now)
    limits = request["limits"]
    isolation = if routine.provider == :codex, do: "read_only", else: "local"
    tools = if routine.mcp, do: Routine.mcp_tools(routine.role), else: []
    tools = tools ++ external_tools(contract.args)

    facts = %{
      id: id,
      provider: to_string(routine.provider),
      model: routine.model,
      effort: if(routine.effort, do: to_string(routine.effort)),
      config_revision: Routine.execution_revision(routine),
      profile_revision: digest(contract),
      isolation: isolation,
      tools: tools,
      observation: observation,
      score: score(declared, observation),
      effective_limits: %{
        calls: min(limits["calls"], routine.max_turns),
        usd: min(limits["usd"], routine.max_budget_usd),
        time_ms: min(limits["time_ms"], routine.timeout_ms)
      },
      current_grant: "not_captured_preview_cannot_authorize_effects",
      reasons: []
    }

    checks = [
      {not is_nil(declared), "unsupported_exact_triple"},
      {pin_matches?(request["pin"], facts), "pin_conflict"},
      {floor_met?(declared, request, policy), "below_quality_floor"},
      {request["isolation"] in ["any", isolation], "isolation_unavailable"},
      {Enum.all?(request["required_tools"], &(&1 in tools)), "required_tool_unavailable"},
      {capabilities_met?(declared, request), "required_capability_unavailable"},
      {request["context_provider"] in [nil, facts.provider], "native_context_provider_conflict"},
      {not SpendLedger.over_rail?(routine), "daily_rail_exhausted"},
      {request["class"] in @classes or id == request["configured_route"],
       "unknown_task_requires_configured_route"},
      {observation.rejected == false, "provider_rejected"},
      {not is_nil(facts.score), "capacity_unknown_or_stale"},
      {is_nil(facts.score) or facts.score > 0, "capacity_exhausted"}
    ]

    %{facts | reasons: for({false, reason} <- checks, do: reason)}
  end

  defp external_tools(args) do
    capture = args["custode_integration_capture"] || %{}

    for entry <- capture[:entries] || capture["entries"] || [],
        (entry[:disposition] || entry["disposition"]) == "configured",
        tool <- entry[:allowed_tools] || entry["allowed_tools"] || [],
        do: "mcp__#{entry[:name] || entry["name"]}__#{tool}"
  end

  defp observation(provider, policy, now) do
    snapshot = Availability.current(provider)
    usage = Availability.usage(provider, now: now, max_age_seconds: policy.max_age_seconds)
    future? = snapshot && DateTime.compare(snapshot.observed_at, now) == :gt
    windows = usage.windows

    rejected = rejected?(windows, usage.freshness)

    known = usage.freshness == :fresh and not future? and known_windows?(windows)

    pressure = if known, do: Enum.max(Enum.map(windows, & &1.utilization))

    %{
      source: if(snapshot, do: snapshot.source, else: "none"),
      observed_at: usage.observed_at,
      freshness: if(future?, do: :unknown, else: usage.freshness),
      windows: windows,
      rejected: rejected,
      pressure: pressure,
      available_fraction: if(known, do: 1 - pressure - policy.interactive_reserve),
      reservation: "operator_configured_interactive_fraction_not_a_live_lease"
    }
  end

  defp rejected?(windows, freshness),
    do: Enum.any?(windows, &(&1.status == :rejected and (freshness == :fresh or &1.held)))

  defp known_windows?(windows), do: windows != [] and Enum.all?(windows, &known_window?/1)

  defp known_window?(window),
    do:
      is_number(window.utilization) and window.utilization >= 0 and window.utilization <= 1 and
        window.status != :unknown

  defp score(nil, _observation), do: nil
  defp score(_declared, %{available_fraction: nil}), do: nil
  defp score(declared, observation), do: observation.available_fraction / declared.weight

  defp floor_met?(nil, _request, _policy), do: false

  defp floor_met?(declared, request, policy),
    do:
      declared.tier >=
        Map.get(
          policy.floors,
          request["class"] <> "/" <> request["phase"],
          Map.get(policy.floors, request["class"], 3)
        )

  defp capabilities_met?(nil, _request), do: false

  defp capabilities_met?(declared, request),
    do: Enum.all?(request["required_capabilities"], &(&1 in declared.capabilities))

  defp pin_matches?(nil, _facts), do: true

  defp pin_matches?(pin, facts),
    do:
      Enum.all?(pin, fn {key, value} -> Map.get(facts, String.to_existing_atom(key)) == value end)

  defp choose([], _request), do: nil

  defp choose(eligible, request) do
    if request["class"] in @classes do
      eligible |> Enum.sort_by(&{-&1.score, &1.id}) |> List.first()
    else
      Enum.find(eligible, &(&1.id == request["configured_route"]))
    end
  end

  defp status(selected, _candidates, _request) when not is_nil(selected), do: "selected"

  defp status(nil, candidates, %{"pin" => pin}) when is_map(pin) do
    if Enum.any?(candidates, &(&1[:reasons] == ["capacity_unknown_or_stale"])),
      do: "deferred",
      else: "unsupported_pin"
  end

  defp status(nil, _candidates, _request), do: "deferred"

  defp valid_request(request) when is_map(request) do
    valid =
      Enum.all?([
        Map.keys(request) -- @keys == [],
        Enum.all?(
          ~w(request_id task_id input_revision class phase isolation),
          &text?(request[&1])
        ),
        request["phase"] in @phases,
        request["isolation"] in ~w(any read_only local),
        list?(request["candidate_ids"], 20),
        request["candidate_ids"] != [],
        list?(request["required_tools"], 100),
        list?(request["required_capabilities"], 20),
        list?(request["context_refs"], 20),
        pin?(request["pin"]),
        request["context_provider"] in [nil, "claude", "codex"],
        limits?(request["limits"])
      ])

    if valid, do: :ok, else: {:error, :invalid_request}
  end

  defp valid_request(_request), do: {:error, :invalid_request}
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..200

  defp list?(value, max),
    do: is_list(value) and length(value) <= max and Enum.all?(value, &text?/1)

  defp pin?(nil), do: true

  defp pin?(value) when is_map(value),
    do:
      map_size(value) > 0 and Map.keys(value) -- ~w(id provider model effort) == [] and
        Enum.all?(Map.values(value), &text?/1)

  defp pin?(_value), do: false

  defp limits?(value) when is_map(value),
    do:
      Map.keys(value) |> Enum.sort() == ~w(calls time_ms usd) and
        is_integer(value["calls"]) and value["calls"] in 1..100 and
        is_integer(value["time_ms"]) and value["time_ms"] in 1..3_600_000 and
        is_number(value["usd"]) and value["usd"] > 0 and value["usd"] <= 100

  defp limits?(_value), do: false

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
