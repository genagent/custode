defmodule Custode.MCP.ReadTools do
  @moduledoc """
  The reads an MCP client could not reach (#346 / survey #345).

  Custode grew eleven capabilities that existed only as functions the
  dashboard called. Every one was something the UI could do and an external
  client could not, which is the private API design/007 said the fleet should
  not have.

  ## Registering is not granting

  These are registered on the MCP server and, with one deliberate exception
  under discussion, granted to NO agent. `Custode.MCP.Server` decides what
  exists; `Custode.Routine`'s allowlists decide who may call it.

  That split is what makes this cheap. Handing eleven fleet-wide reads to
  every sweep would give each one eleven new ways to spend itself, and an
  agent reading the fleet's attention ranking is an agent re-deriving what it
  already is. These are for the operator: the `mix custode` CLI, and whatever
  else drives the fleet from outside.

  ## Shapes are flattened on the way out

  Signals, records and items are structs. They are converted to plain maps
  here rather than derived into JSON encoders, so the wire shape is a
  deliberate choice at the boundary instead of a consequence of an internal
  struct's field list.
  """

  @doc false
  def signal_map(signal) do
    %{
      subject: signal.subject,
      kind: signal.kind,
      group: signal.group,
      urgency: signal.urgency,
      headline: signal.headline,
      detail: signal.detail,
      raised_at: signal.raised_at,
      resolving: Enum.map(signal.resolving, &%{label: &1.label, op: &1.op, args: &1.args})
    }
  end

  @doc false
  def item_map(item) do
    %{
      kind: item.kind,
      subject: item.subject,
      headline: item.headline,
      detail: item.detail,
      at: item.at,
      actions: Enum.map(item.actions, &%{label: &1.label, op: &1.op, args: &1.args})
    }
  end
end

defmodule Custode.MCP.ReadTools.Attention do
  @moduledoc """
  The fleet's ranked attention: one signal per agent, ordered so the thing
  most owed a human is first.

  The single most valuable read custode has, and the one an external client
  most obviously lacked. `list_routines` answers "what exists" and returns raw
  lifecycle states; this answers "what needs me", which is the question the
  whole resolver was built for (#296).

  Grouped by default, because the groups carry the meaning: `needs_you` is
  nothing-progresses-without-you, `watching` is the fleet noticed and is not
  blocked, and the rest are healthy.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Attention.Fleet
  alias Custode.MCP.ReadTools

  schema do
    field(:group, :string,
      description: "only this group: needs_you | watching | working | scheduled | quiet"
    )
  end

  @impl true
  def execute(params, frame) do
    grouped =
      for {group, signals} <- Fleet.by_group(),
          matches?(group, params[:group]) do
        %{group: group, signals: Enum.map(signals, &ReadTools.signal_map/1)}
      end

    reply(frame, %{groups: grouped})
  end

  defp matches?(_group, nil), do: true
  defp matches?(group, wanted), do: to_string(group) == wanted
end

defmodule Custode.MCP.ReadTools.Inbox do
  @moduledoc """
  What the fleet has raised to the operator: questions, approvals, reached
  rails, and standing advisor suggestions.

  Distinct from `inbox_list`, which is an AGENT's own note inbox. This is the
  human's side (#301), and the two are different things that unfortunately
  share a word.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.MCP.ReadTools
  alias Custode.Operator.Inbox

  schema do
    field(:unread_only, :boolean, description: "only what arrived since the operator last looked")
  end

  @impl true
  def execute(params, frame) do
    last_read = Inbox.last_read_at()

    items =
      if params[:unread_only],
        do: Inbox.since(last_read),
        else: Inbox.items()

    reply(frame, %{
      items: Enum.map(items, &ReadTools.item_map/1),
      last_read_at: last_read
    })
  end
end

defmodule Custode.MCP.ReadTools.Suggestions do
  @moduledoc """
  Standing advisor suggestions: what the fleet proposes changing about itself.

  Reading them over MCP was impossible, which meant an external client could
  not even SEE the advisors' proposals, let alone act on them. Acting is
  tier 2 (#347).
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame), do: reply(frame, %{suggestions: Custode.Suggestions.standing()})
end

defmodule Custode.MCP.ReadTools.SuggestionOutcomes do
  @moduledoc """
  What became of the operator's decisions: applied and still in force,
  reverted, superseded, or dismissed and why (#329).

  Deliberately reports facts rather than a verdict. Whether a change did what
  it promised depends on what it promised, which is per-advisor.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Suggestions.Outcome

  schema do
    field(:days, :integer, description: "window in days (default 30)")
  end

  @impl true
  def execute(params, frame) do
    opts = if days = params[:days], do: [since: days * 24 * 60 * 60], else: []

    decisions =
      for record <- Outcome.history(opts) do
        %{
          agent: record.agent,
          advisor: record.advisor,
          field: record.field,
          proposed: record.proposed,
          decision: record.decision,
          status: record.status,
          reason: record.reason,
          at: record.at,
          observed: record.observed,
          summary: Outcome.describe(record)
        }
      end

    reply(frame, %{decisions: decisions})
  end
end

defmodule Custode.MCP.ReadTools.Advisors do
  @moduledoc """
  Each advisor's record: what it proposed, what became of it, what it cost
  (#332).

  Read comparatively. A fleet-wide rejection rate near zero can mean the
  proposals are excellent or that the approvals are reflexive; one advisor
  rejected far more than its siblings is the signal that survives either
  reading.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Advisors.Record

  schema do
    field(:days, :integer, description: "window in days (default 30)")
  end

  @impl true
  def execute(params, frame) do
    opts = if days = params[:days], do: [since: days * 24 * 60 * 60], else: []

    advisors =
      for entry <- Record.all(opts) do
        entry
        |> Map.from_struct()
        |> Map.put(:summary, Record.describe(entry))
      end

    reply(frame, %{advisors: advisors})
  end
end

defmodule Custode.MCP.ReadTools.Metrics do
  @moduledoc """
  The fleet's numbers, one tool over the several `Custode.Metrics` answers.

  One tool with a `kind` rather than six tools, because they share a window
  argument and differ only in what they count -- six names would spend six
  slots in every allowlist and tool listing to say the same thing.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @kinds ~w(spend turns gate_latency by_model gate_outcomes prs_opened)

  schema do
    field(:kind, :string, required: true, description: "one of: #{Enum.join(@kinds, ", ")}")
    field(:days, :integer, description: "window in days (default 7)")
  end

  @impl true
  def execute(%{kind: kind} = params, frame) when kind in @kinds do
    days = params[:days] || 7
    reply(frame, %{kind: kind, days: days, data: measure(kind, days)})
  end

  def execute(%{kind: kind}, frame),
    do: fail(frame, "unknown metric #{kind}; known: #{Enum.join(@kinds, ", ")}")

  defp measure("spend", days), do: Custode.Metrics.daily_by_agent(days)
  defp measure("turns", days), do: Custode.Metrics.turns_by_day(days)

  defp measure("gate_latency", _days) do
    {gates, median_minutes} = Custode.Metrics.gate_latencies()
    %{gates: gates, median_minutes: median_minutes}
  end

  defp measure("by_model", days), do: Custode.Metrics.by_model(days)
  defp measure("gate_outcomes", days), do: Custode.Metrics.gate_outcomes(days)
  # {repo, number} tuples do not survive JSON either.
  defp measure("prs_opened", days) do
    days
    |> Custode.Metrics.prs_opened()
    |> Map.new(fn {agent, prs} ->
      {agent, for({repo, number} <- prs, do: %{repo: repo, number: number})}
    end)
  end
end

defmodule Custode.MCP.ReadTools.Digest do
  @moduledoc """
  The "while you were away" summary: what the fleet did over a window, as the
  dashboard renders it on the operator's return (#263).
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:days, :integer, description: "window in days (default 1)")
    field(:markdown, :boolean, description: "render as markdown instead of the typed map")
  end

  @impl true
  def execute(params, frame) do
    digest = Custode.Digest.build(params[:days] || 1)

    if params[:markdown] do
      reply(frame, %{markdown: Custode.Digest.to_markdown(digest)})
    else
      reply(frame, digest)
    end
  end
end

defmodule Custode.MCP.ReadTools.Roles do
  @moduledoc """
  The role registry: what each role is for, where it sits in the tree, what
  it watches and writes, and which tool bundle its tier grants.

  The single source of truth for the fleet's permission model
  (`Custode.Roles`), and it was readable only from inside.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    roles =
      for {role, meta} <- Custode.Roles.all() do
        meta
        |> Map.put(:role, role)
        |> Map.put(:grants, Custode.Roles.grants(role))
      end

    reply(frame, %{roles: roles, tiers: Custode.Roles.tiers()})
  end
end

defmodule Custode.MCP.ReadTools.Policies do
  @moduledoc """
  The fleet's declared policies, and which bind a given routine (#50).

  What an approver is meant to review against. Without this a client can see
  a gate and not the rule it should be judged by.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, description: "only the policies binding this routine")
  end

  @impl true
  def execute(params, frame) do
    policies =
      case params[:agent_id] && Custode.Routine.get(params[:agent_id]) do
        nil -> Custode.Policy.all()
        routine -> Custode.Policy.for_routine(routine)
      end

    reply(frame, %{policies: Enum.map(policies, &policy_map/1)})
  end

  # `applies` is `:all` or a KEYWORD LIST, and a keyword list is a list of
  # tuples, which does not survive JSON. Flattening it here is the boundary
  # doing its job rather than leaking an internal shape and failing at encode.
  defp policy_map(policy) do
    %{policy | applies: applies_map(policy.applies)}
  end

  defp applies_map(:all), do: "all"

  defp applies_map(selectors) when is_list(selectors),
    do: for({selector, value} <- selectors, do: %{selector: selector, value: value})

  defp applies_map(other), do: inspect(other)
end

defmodule Custode.MCP.ReadTools.Workflows do
  @moduledoc """
  The workflow catalog: the deep digs that exist to be launched (#271).

  Reading the catalog is free and safe. LAUNCHING one is tier 2 (#347) and
  waits on the launch gate (#272), because #307 kept launching to iex on
  purpose until there is a gate and a budget rail.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Workflow.Catalog

  schema do
  end

  @impl true
  def execute(_params, frame) do
    workflows =
      for name <- Catalog.names() do
        case Catalog.fetch(name) do
          {:ok, workflow} -> %{name: name, stages: length(workflow.stages)}
          :error -> %{name: name}
        end
      end

    reply(frame, %{workflows: workflows})
  end
end

defmodule Custode.MCP.ReadTools.ExecutingTurns do
  @moduledoc """
  What is running right now: the turns Oban has claimed and not yet finished.

  The read behind `drain`'s decision to wait, and the honest answer to "is
  the fleet busy" -- which a status listing cannot give, because an agent
  reads `:running` for the whole turn whether it started a second ago or is
  wedged.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame), do: reply(frame, %{executing: Custode.executing_turns()})
end
