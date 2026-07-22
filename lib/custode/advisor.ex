defmodule Custode.Advisor do
  @moduledoc """
  The advisor behaviour (#125): the fleet-tuning sibling of `Custode.Sensor`.

  Sensors watch the WORLD and drop notes in a routine's inbox. Advisors watch
  the FLEET -- spend, feed, gates, config -- and produce typed SUGGESTIONS
  addressed to the operator. Same mechanical chassis (a plain worker on the
  `:sensors` queue, riding the static crontab like the janitor), same
  seen-set discipline so a standing suggestion does not re-nag; a different
  audience and output object.

  Deterministic by contract: `observe/0` and `suggest/1` are pure Elixir over
  existing queries -- an advisor sweep costs zero tokens. "Survey cheap"
  taken to its limit.

  An advisor implements three decisions:

      defmodule Custode.Advisors.Whatever do
        use Custode.Advisor
        @impl true
        def observe, do: [...]                # deterministic reads
        @impl true
        def suggest(observations), do: [...]  # suggestion maps
        @impl true
        def key(suggestion), do: "..."        # identity for the cooldown
      end

  A suggestion is a map with `:routine_id`, `:field`, `:current`,
  `:proposed`, `:evidence`, and `:confidence` (`:low | :medium | :high`).
  Suggestions land in the feed as `advisor_suggestion` entries -- visible on
  the dashboard and durable, per the storage doctrine. Accept/dismiss cards
  are a later slice; advisors SUGGEST and never touch config themselves (the
  operator, or a gated write-back, is always the actuator).

  Cooldown: the seen-set holds each suggestion's `key/1` (encode the material
  evidence in the key -- a dismissed suggestion should only return when the
  facts change). Keys are replaced wholesale each run, sensor-style, so a
  suggestion that stops being made ages out and may honestly return later.
  """

  @callback observe() :: [term()]
  @callback suggest(observations :: [term()]) :: [map()]
  @callback key(suggestion :: map()) :: String.t()

  defmacro __using__(_opts) do
    quote do
      use Oban.Worker, queue: :sensors, max_attempts: 1

      @behaviour Custode.Advisor

      @impl Oban.Worker
      def perform(%Oban.Job{}) do
        Custode.Advisor.run(__MODULE__)
      end
    end
  end

  @doc false
  def run(module) do
    advisor_id = advisor_id(module)
    suggestions = module.observe() |> module.suggest()
    current_keys = MapSet.new(suggestions, &module.key/1)
    memory_key = "advisor:" <> advisor_id

    seen =
      case Custode.Memory.recall(memory_key, "seen") do
        {:ok, json} -> json |> Jason.decode!() |> MapSet.new()
        :error -> MapSet.new()
      end

    fresh = Enum.reject(suggestions, &MapSet.member?(seen, module.key(&1)))

    Custode.Memory.remember(memory_key, "seen", Jason.encode!(MapSet.to_list(current_keys)))

    Enum.each(fresh, fn suggestion ->
      Custode.Feed.record(%{
        event: "advisor_suggestion",
        agent: suggestion[:routine_id] || "custode",
        advisor: advisor_id,
        field: to_string(suggestion.field),
        current: to_string(suggestion.current),
        proposed: to_string(suggestion.proposed),
        confidence: to_string(suggestion.confidence),
        # a field of its own, not just prose inside the summary: the rail's
        # cards (#178) show the reasoning without parsing a sentence apart
        evidence: to_string(suggestion.evidence),
        summary:
          "#{advisor_id} suggests #{suggestion[:routine_id]}: #{suggestion.field} " <>
            "#{suggestion.current} -> #{suggestion.proposed} -- #{suggestion.evidence}"
      })
    end)

    Custode.Feed.record(%{
      event: "sensor",
      agent: "custode",
      sensor_id: advisor_id,
      summary:
        "#{advisor_id}: #{length(fresh)} new suggestion(s), #{length(suggestions)} standing"
    })

    :ok
  end

  defp advisor_id(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> then(&("advisor-" <> &1))
  end
end
