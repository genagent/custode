defmodule Custode.MCP.OperatorTools do
  @moduledoc """
  The operator tier of the toolbox (issue #33): everything an external agent
  needs to RUN the fleet, not just delegate work into it. Grown from a live
  session where an operator agent drove custode over MCP but had to reach
  for side doors (sqlite inserts, raw file writes) for beats, notes, gates,
  the feed, pause/resume, and spend.

  Same server and trust tier as the fleet tools: which agents can operate
  siblings is already a per-routine `mcp: true` decision, and the HTTP
  surface is localhost-only (auth is issue #1).
  """
end

defmodule Custode.MCP.OperatorTools.Beat do
  @moduledoc """
  Fire one sweep of a routine right now: an out-of-schedule tick through the
  same lifecycle policy as the cron entry, so it boots the agent if offline.
  The operator's "wake up and look" verb.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "the routine to beat")
  end

  @impl true
  def execute(%{agent_id: agent_id}, frame) do
    case Custode.Routine.get(agent_id) do
      nil ->
        fail(frame, "unknown routine: #{agent_id}")

      _routine ->
        {:ok, job_id} = Custode.beat(agent_id)
        reply(frame, %{agent_id: agent_id, job_id: job_id, state: "beat scheduled"})
    end
  end
end

defmodule Custode.MCP.OperatorTools.DropNote do
  @moduledoc """
  Drop a note into a routine's inbox THROUGH the funnel: the note is written
  and the routine's event kickoff fires (a debounced beat, honoring its
  on_note policy). A bare file write wakes nobody; this does. The manual
  equivalent of a sensor detection.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string,
      required: true,
      description: "the routine whose inbox gets the note"
    )

    field(:name, :string, description: "note filename (a timestamped default applies)")
    field(:content, :string, required: true, description: "markdown body of the note")
  end

  @impl true
  def execute(%{agent_id: agent_id, content: content} = params, frame) do
    name = params[:name] || default_name()

    case Custode.Inbox.drop(agent_id, name, content) do
      {:ok, path} -> reply(frame, %{agent_id: agent_id, path: path})
      {:error, reason} -> fail(frame, "drop failed: #{inspect(reason)}")
    end
  end

  defp default_name do
    "note-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> ".md"
  end
end

defmodule Custode.MCP.OperatorTools.ListGates do
  @moduledoc """
  Recent gates fleet-wide, newest first: open ones carry the action_id an
  approve_action / reject_action call needs. The durable answer to "what is
  waiting on a human?" without reading the database.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Gates.Review

  schema do
    field(:status, :string, description: "filter: open | resolved | requeued | orphaned")
    field(:limit, :integer, description: "max rows (default 20)")
  end

  @impl true
  def execute(params, frame) do
    gates =
      for gate <- Custode.Gates.recent(params[:limit] || 20, params[:status]) do
        %{
          agent_id: gate.agent_id,
          kind: gate.kind,
          action_id: gate.action_id,
          detail: gate.detail,
          class: gate.class,
          repo: gate.repo,
          pr_number: gate.pr_number,
          risk: gate.risk,
          review_state: gate.review_state,
          review: review(gate.review),
          status: gate.status,
          opened_at: gate.inserted_at
        }
      end

    reply(frame, %{gates: gates})
  end

  defp review(%Review{} = review) do
    %{
      provider: review.reviewer_provider,
      head_sha: review.head_sha,
      summary: review.summary,
      findings: Review.findings(review),
      error: review.error
    }
  end

  defp review(_none), do: nil
end

defmodule Custode.MCP.OperatorTools.FeedTail do
  @moduledoc "The last N feed entries (optionally one agent's): operator situational awareness."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, description: "restrict to one agent")
    field(:n, :integer, description: "how many entries (default 20)")
  end

  @impl true
  def execute(params, frame) do
    n = params[:n] || 20

    entries =
      case params[:agent_id] do
        nil -> Custode.Feed.tail(n)
        agent_id -> Custode.Feed.for_agent(agent_id, n)
      end

    reply(frame, %{entries: entries})
  end
end

defmodule Custode.MCP.OperatorTools.PauseAgent do
  @moduledoc "Emergency-pause an agent: it finishes nothing further until resumed."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools
  alias Custode.Operations.Fleet.PauseAgent, as: Operation

  schema do
    field(:agent_id, :string, required: true, description: "the agent to pause")
    field(:idempotency_key, :string, description: "stable key for retrying one logical pause")
  end

  def definition, do: Operation.definition()
  def name, do: definition().projection.mcp.name

  @impl true
  def execute(%{agent_id: agent_id} = params, frame) do
    options = [
      actor: Custode.MCP.caller(frame),
      transport: Custode.MCP.origin_transport(frame),
      idempotency_key: params[:idempotency_key] || Ecto.UUID.generate()
    ]

    case Operation.dispatch(agent_id, options) do
      {:ok, %{result: result}} -> reply(frame, result)
      {:error, reason} -> fail(frame, "pause failed: #{inspect(reason)}")
    end
  end
end

defmodule Custode.MCP.OperatorTools.ResumeAgent do
  @moduledoc "Resume a paused agent (the human-override exit from any pause, including budget)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, required: true, description: "the agent to resume")
  end

  @impl true
  def execute(%{agent_id: agent_id}, frame) do
    case Custode.Agents.resume_agent(agent_id) do
      :resumed -> reply(frame, %{agent_id: agent_id, state: "resumed"})
      {:error, reason} -> fail(frame, "resume failed: #{inspect(reason)}")
    end
  end
end

defmodule Custode.MCP.OperatorTools.SpendToday do
  @moduledoc """
  Today's spend: per routine with its daily rail, plus the fleet total.
  "Today" starts at midnight in the fleet's configured timezone, NOT UTC; the
  reply's `since` and `timezone` say exactly which window was counted, so a
  total of zero just after local midnight reads as a new day and not as a
  broken ledger.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    routines =
      for routine <- Custode.Routine.all() do
        %{
          agent_id: routine.id,
          today_usd: Custode.SpendLedger.today(routine.id),
          daily_budget_usd: routine.daily_budget_usd,
          today_tokens: Custode.SpendLedger.today_tokens(routine.id),
          daily_budget_tokens: routine.daily_budget_tokens
        }
      end

    reply(frame, %{
      since: DateTime.to_iso8601(Custode.SpendLedger.day_started_at()),
      timezone: Application.get_env(:custode, :timezone, "Etc/UTC"),
      routines: routines,
      fleet_today_usd: Custode.SpendLedger.fleet_today(),
      fleet_today_tokens: Custode.SpendLedger.fleet_today_tokens()
    })
  end
end

defmodule Custode.MCP.OperatorTools.SetPresence do
  @moduledoc """
  Set operator presence (#141): "away" pins away, "present" pins present,
  "auto" restores inference and counts as a fresh operator action. Sweeps
  read the presence line and shape themselves to it -- away means agents
  queue at most one well-chosen gate for morning instead of parking early.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:mode, :string, required: true, description: ~s(one of "present", "away", "auto"))
  end

  @impl true
  def execute(%{mode: mode}, frame) when mode in ["present", "away", "auto"] do
    {state, _at} = Custode.Presence.set(String.to_existing_atom(mode))
    reply(frame, %{mode: mode, reading: to_string(state)})
  end

  def execute(%{mode: mode}, frame),
    do: fail(frame, ~s(mode must be "present", "away", or "auto"; got #{inspect(mode)}))
end
