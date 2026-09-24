defmodule Custode.Attention do
  @moduledoc """
  The shared Attention surface.

  `resolve/2`, `rank/1`, and `by_group/1` preserve the pure compatibility
  resolver from one legacy agent's facts to a `Custode.Signal`.

  `list/1` is the work-first projection: current operator obligations derived
  from authoritative Mission, WorkItem, Gate, OperationCall, ask, and legacy
  gate records. It is transport-neutral, deterministically paginated, and
  never stored as independent truth.

  ## Why this is a module and not a sort key

  The fleet page currently ranks itself, inline, in `CustodeWeb.FleetLive`:

      {if(needs_attention?(tile.status), do: 0, else: 1),
       if(tile.state == :ended, do: 1, else: 0), activity_key(tile.last_activity), id}

  Attention is binary there, so everything that needs a human is then ordered
  by recency. On the live fleet that inverts the thing the operator wants: the
  OLDEST unanswered question sorts LAST among the agents needing attention,
  under four approvals raised in the last few minutes. Staleness is exactly
  what should rise, and recency-sorting is what buries it.

  Moving the decision here buys three things. It is testable, because it does
  no IO and reads no clock it was not handed. It is single, so the fleet page,
  the inbox, the digest and the CLI cannot drift into four slightly different
  ideas of what needs a human. And it is inspectable, because the result is a
  value the operator's judgment can be compared against rather than a sort
  key buried in a template.

  Everything here is pure. The impure half -- reading the registry, the gate
  rows and the ledger -- is `Custode.Attention.Fleet`.

  ## Precedence

  One agent resolves to ONE signal: the first kind whose condition holds.

  | # | kind | condition |
  | - | ---- | --------- |
  | 1 | `:red_main` | the repository's default branch is failing (#310) |
  | 2 | `:turn_failing` | the agent's last turn failed for a reason the next beat cannot fix (#527) |
  | 3 | `:needs_answer` | an open question, blocking or not (#299) |
  | 4 | `:approval` | a gate is open that only the operator can pass |
  | 5 | `:disowned_check` | a red check the agent declared not its work (#313) |
  | 6 | `:red_check` | failing checks on the agent's own open PRs |
  | 7 | `:sensor_failing` | one of the agent's sensors has failed N runs in a row (#444) |
  | 8 | `:rail_hit` | the daily rail is reached |
  | 9 | `:stalled` | scheduled, running, producing no outcome (NOT IMPLEMENTED) |
  | 10 | `:working` | a turn is executing right now |
  | 11 | `:paused` | deliberately stopped |
  | 12 | `:scheduled` | healthy, next beat known |
  | 13 | `:quiet` | healthy, nothing found, nothing queued |

  A question outranks an approval because a question is blocked on a human by
  definition, whereas a gate is a structured hold the agent chose to raise and
  can describe. Both outrank a red check, which may still be the agent's to
  fix.

  Precedence is which kind WINS for one agent. Which group it lands in is a
  separate question, and `:red_check` is the case that separates them: it
  outranks a rail hit for a single agent, but it is not something the operator
  owes anyone. See `Custode.Signal` for the `:needs_you` / `:watching` split
  and why a red check sits in the second.

  `:red_main` is the case that shows the split is about OWNERSHIP rather than
  severity. A red pull request blocks nobody but the agent, so the fleet keeps
  it. A red default branch makes merging unsafe and can make a restart fail
  outright, so it invalidates the operator's own next action and is owed to
  them whether or not an agent is also on it (#310).

  ### Kinds with no agent

  `:host_down`, `:workflow_launch` and `:workflow_rail` are absent from the
  table because no agent's view resolves to them. A failed boot doctor belongs
  to the host, and a workflow launch or a parked run belongs to a run that has
  no gen_statem behind it. `host/1` and `workflows/1` build them from their
  own facts; they share `@precedence` and `@groups` with everything else, so
  ranking and grouping stay in this one module.

  ### Two deliberate departures from the design note

  `:paused` is checked BEFORE `:scheduled`, not last. A paused routine still
  has a cron, so testing `:scheduled` first would report an agent the operator
  stopped as healthy and counting down to a beat it will never run. The
  precedence claim that matters is the ordering WITHIN the needs-you kinds;
  the rest states are mutually exclusive and their order is a correctness
  question, not a ranking one.

  `:stalled` is defined and NOT implemented. A false stall is worse than no
  stall detection: it teaches the operator to distrust the needs-you group,
  which is the entire value of ranking. It needs a threshold tuned against
  real sweep history first, and it stays off until then.

  ## Offline is a rest state, not a fault

  Custode routines are cold-started by their own cron (`if_offline: "start"`),
  so a healthy scheduled agent reads `:offline` between beats for most of its
  life -- which is why the fleet page shows so many. An offline agent with a
  cron is `:scheduled`; an offline agent without one is `:quiet`. Neither is a
  problem, and drawing them as one is most of why the current page is hard to
  scan.
  """

  alias Custode.Attention.Projection
  alias Custode.Signal
  alias Custode.TurnFailure

  # Ranked kinds, most urgent first. The index into this list IS the
  # precedence, so the table in the moduledoc and the ordering cannot drift.
  @precedence [
    :host_down,
    :red_main,
    :turn_failing,
    :needs_answer,
    :approval,
    :workflow_launch,
    :disowned_check,
    :red_check,
    :sensor_failing,
    :rail_hit,
    :workflow_rail,
    :stalled,
    :working,
    :paused,
    :scheduled,
    :quiet
  ]

  @groups %{
    host_down: :needs_you,
    red_main: :needs_you,
    turn_failing: :needs_you,
    needs_answer: :needs_you,
    approval: :needs_you,
    workflow_launch: :needs_you,
    disowned_check: :needs_you,
    red_check: :watching,
    sensor_failing: :watching,
    rail_hit: :needs_you,
    workflow_rail: :needs_you,
    stalled: :needs_you,
    working: :working,
    scheduled: :scheduled,
    quiet: :quiet,
    paused: :quiet
  }

  @group_order [:needs_you, :watching, :working, :scheduled, :quiet]
  @urgency_order [:high, :normal, :low]

  # Consecutive failed runs before a sensor is worth a signal, when the caller
  # hands no threshold in. Production passes the configured one through the
  # context (`Custode.Sensor.Health.threshold/0`).
  @sensor_failure_threshold 3

  # A rail is "hit" at 100%; the fleet page's own 80% banner (#211) stays a
  # separate, softer warning and is not an attention signal.
  @rail_hit_ratio 1.0

  @doc "The kinds, most urgent first."
  @spec kinds() :: [Signal.kind()]
  def kinds, do: @precedence

  @doc "List current work-first Attention items."
  @spec list(keyword() | map()) :: {:ok, Projection.page()} | {:error, term()}
  def list(options \\ []), do: Projection.list(options)

  @doc "The groups, in the order a page should stack them."
  @spec groups() :: [Signal.group()]
  def groups, do: @group_order

  @doc """
  The group a kind collapses into.

      iex> Custode.Attention.group_of(:needs_answer)
      :needs_you

      iex> Custode.Attention.group_of(:paused)
      :quiet
  """
  @spec group_of(Signal.kind()) :: Signal.group()
  def group_of(kind), do: Map.fetch!(@groups, kind)

  @doc """
  The fleet-scoped signal, or `nil`: a condition with no single agent as its
  subject, so there is no view to resolve it from (#443).

  Today that is one thing, a failed boot doctor. It outranks every per-agent
  kind because it invalidates all of them: with ticks withheld no agent will
  act on anything, so an open gate below it is waiting on a fleet that cannot
  run. The subject is `"custode"`, the system itself.

  `resolving` is empty on purpose. Nothing the running node can do clears it;
  the fix is on the host and then a restart, and the detail says so.

      iex> Custode.Attention.host(%{doctor: :unknown})
      nil
  """
  @spec host(%{doctor: Custode.Host.doctor()}) :: Signal.t() | nil
  def host(%{doctor: {:failed, report, at}}) do
    %Signal{
      subject: "custode",
      kind: :host_down,
      group: group_of(:host_down),
      urgency: :high,
      headline: "no agent can run: the boot doctor failed",
      detail: report <> ". Ticks are withheld. Fix the host, then restart.",
      raised_at: at,
      resolving: []
    }
  end

  def host(_facts), do: nil

  @doc """
  The workflow signals: every launch proposal waiting on a decision and every
  run parked on its budget rail (#447).

  Both are owed to the operator and to nobody else. design/005 makes the
  launch gate the only path to a run, and a parked run stays parked until a
  human raises the rail or lets it go. Until #447 neither entered this module,
  so the inbox said "That's everything." and the chip stayed empty while they
  waited on `/workflows`, a page with no reason to be open.

  Like `host/1` there is no agent view to resolve these from, so they are
  built from their own facts, gathered by `Custode.Attention.Fleet`:

    * `:launches` -- each as `%{id:, workflow:, repo:, summary:, why:,
      proposed_at:}`.
    * `:paused_runs` -- each as `%{run_id:, workflow:, repo:, reason:,
      paused_at:}`, the reason being the run's own note of what it spent and
      which nodes it did not run.

  The subject is the workflow and the repository, which is how the operator
  tells two of them apart; the ops carry the proposal or run id.

      iex> Custode.Attention.workflows(%{launches: [], paused_runs: []})
      []
  """
  @spec workflows(%{launches: [map()], paused_runs: [map()]}) :: [Signal.t()]
  def workflows(facts) do
    Enum.map(Map.get(facts, :launches, []), &workflow_launch/1) ++
      Enum.map(Map.get(facts, :paused_runs, []), &workflow_rail/1)
  end

  defp workflow_launch(launch) do
    %Signal{
      subject: workflow_subject(launch),
      kind: :workflow_launch,
      group: group_of(:workflow_launch),
      urgency: :high,
      headline: "wants your approval to launch",
      detail: [launch[:why], launch[:summary]] |> Enum.reject(&blank?/1) |> Enum.join("\n"),
      item: {:proposal, launch.id},
      raised_at: launch[:proposed_at],
      resolving: [
        op("Approve", :approve_launch, %{proposal: launch.id}),
        op("Reject", :reject_launch, %{proposal: launch.id}),
        op("Open workflows", :open_workflows, %{})
      ]
    }
  end

  # "Raise the rail and resume" rather than "Resume": resuming onto the same
  # ceiling parks the run again on its next advance, so the one useful act is
  # the raise. `Custode.Workflow.Launch.raise_and_resume/1` owns by how much.
  defp workflow_rail(run) do
    %Signal{
      subject: workflow_subject(run),
      kind: :workflow_rail,
      group: group_of(:workflow_rail),
      urgency: :high,
      headline: "run #{run.run_id} is parked on its budget rail",
      detail: run[:reason],
      item: {:run, run.run_id},
      raised_at: run[:paused_at],
      resolving: [
        op("Raise the rail and resume", :resume_run, %{run: run.run_id}),
        op("Open workflows", :open_workflows, %{})
      ]
    }
  end

  defp workflow_subject(%{workflow: workflow, repo: repo}), do: "#{workflow} on #{repo}"

  defp blank?(value), do: value in [nil, ""]

  @doc """
  Resolve one agent's view to its single signal.

  `view` is a plain map of facts, built by `Custode.Attention.Fleet` in
  production and written by hand in tests:

    * `:id` -- the agent id. Required.
    * `:state` -- the lifecycle state atom (`:idle`, `:running`, `:paused`,
      `:offline`, `:awaiting_permission`, `:waiting_for_user`, `:ended`).
    * `:live_action_id` -- the provider's current approval id, or `nil`.
    * `:gate` -- the open gate row as `%{kind:, detail:, action_id:,
      opened_at:}`, or `nil`. Supplies the durable `raised_at` that the live
      status cannot: the gen_statem knows it is gated, not since when.
    * `:ask` -- the oldest open non-blocking question as `%{id:, question:,
      asked_at:}`, or `nil` (#299). Independent of state: an agent with an
      open ask is usually idle or working, because asking did not stop it.
    * `:failing_prs` -- the agent's open PRs with failing checks, each as
      `%{number:, disowned?:}` (#313). The gatherer marks them; the resolver
      only partitions, so which side of the line a PR falls on is a fact
      rather than a judgment made twice.
    * `:default_branch` -- the branch build as `%{name:, state:, headline:}`,
      or `nil` (#310). `nil` means unknown, not green: an empty repository and
      a rollup that has not reported yet both land here, and only a reported
      failure is a signal.
    * `:sensor_failures` -- the agent's sensors whose last run failed, each as
      `%{id:, failures:, last_error:, since:}` (#444). Every streak, however
      short: the gatherer reports counts and the resolver holds the threshold,
      the same division as `:spend_today` and the rail.
    * `:turn_failure` -- the agent's trailing run of failed turns with no
      successful turn since, as `%{category:, failures:, detail:, since:}`, or
      `nil` (#527). Only present when the latest failure's category is not
      retryable (`Custode.TurnFailure`); `:failures` counts that category's
      run.
    * `:spend_today` / `:budget` -- the daily ledger and the rail.
    * `:running_since` -- when the in-flight turn started, or `nil`.
    * `:cron` -- the schedule, or `nil` for a manual agent.
    * `:next_beat_at` -- when the next beat is due, if known.

  `context` carries anything the resolver must not read for itself:

    * `:now` -- the clock. Defaults to `DateTime.utc_now/0`, which is the one
      concession to convenience; pass it in tests.
    * `:stalled?` -- opt in to `:stalled` detection. Off, and unimplemented.
    * `:sensor_failure_threshold` -- consecutive failed runs before a sensor
      raises `:sensor_failing`. Defaults to 3.
  """
  @spec resolve(map(), map()) :: Signal.t()
  def resolve(view, context \\ %{}) do
    context = Map.put_new_lazy(context, :now, &DateTime.utc_now/0)

    Enum.find_value(resolvers(), & &1.(view, context))
  end

  # The chain, in precedence order. A list rather than a chain of `||` so that
  # the order lives in ONE place a reader can see at a glance -- and because
  # the `||` version had to be kept in sync with @precedence by hand, which is
  # exactly the kind of duplication this module exists to remove elsewhere.
  #
  # `quiet/2` always returns a signal, so the search always terminates.
  defp resolvers do
    [
      &red_main/2,
      &turn_failing/2,
      &needs_answer/2,
      &approval/2,
      &disowned_check/2,
      &red_check/2,
      &sensor_failing/2,
      &rail_hit/2,
      &stalled/2,
      &working/2,
      &paused/2,
      &scheduled/2,
      &quiet/2
    ]
  end

  @doc """
  Order resolved signals for a human: group, then kind precedence, then
  urgency, then oldest-first, then the id as a stable tiebreak.

  Oldest-first inside a kind is the point. An approval that has been open for
  two hours is a worse state of the world than one raised a minute ago, and
  the current page orders them the other way round.
  """
  @spec rank([Signal.t()]) :: [Signal.t()]
  def rank(signals), do: Enum.sort_by(signals, &sort_key/1)

  @doc """
  Rank, then bucket by group, dropping empty groups.

  Returns a list of `{group, signals}` in `groups/0` order, ready for a page
  that stacks the needs-you rows above a collapsed tail.
  """
  @spec by_group([Signal.t()]) :: [{Signal.group(), [Signal.t()]}]
  def by_group(signals) do
    ranked = Enum.group_by(rank(signals), & &1.group)

    for group <- @group_order, signals = Map.get(ranked, group, []), signals != [] do
      {group, signals}
    end
  end

  defp sort_key(%Signal{} = signal) do
    {
      index_of(@group_order, signal.group),
      index_of(@precedence, signal.kind),
      index_of(@urgency_order, signal.urgency),
      raised_key(signal.raised_at),
      signal.subject
    }
  end

  # Unknown members sort last rather than raising: a ranking function is the
  # wrong place to crash a dashboard over an atom it has not met.
  defp index_of(list, value) do
    case Enum.find_index(list, &(&1 == value)) do
      nil -> length(list)
      index -> index
    end
  end

  # Oldest first, and signals with no timestamp (a red check, which the
  # overview cache cannot date) after the ones that have one.
  defp raised_key(%DateTime{} = at), do: {0, DateTime.to_unix(at, :microsecond)}
  defp raised_key(nil), do: {1, 0}

  # The one CI state that is the operator's business even though an agent may
  # also be working on it (#310): merging onto a red default branch is unsafe
  # and restarting from it can fail outright, so it invalidates the operator's
  # OWN next action. That is the test :red_check fails and this one passes.
  defp red_main(view, _context) do
    branch = Map.get(view, :default_branch)

    if branch && branch.state in ["FAILURE", "ERROR"] do
      signal(view, :red_main, :high,
        headline: "#{branch.name} is red",
        detail: branch.headline,
        item: {:branch, branch.name},
        # No "Re-run checks" op here or on the two red-check signals below:
        # nothing handles one yet, so it rendered as a mislabelled link. It
        # returns with the re-run verb (#449).
        resolving: [op("Open agent", :open_agent, %{agent: view.id})]
      )
    end
  end

  # Three sources, and the third is the point (#299). An open ask means there
  # is a question whether or not the agent is parked, which is what this kind
  # was always supposed to mean. A blocking `ask_user` still resolves here so
  # nothing regresses while the prompt stack still uses it.
  defp needs_answer(view, _context) do
    cond do
      ask = Map.get(view, :ask) ->
        signal(view, :needs_answer, :high,
          headline: "asked you a question",
          detail: ask.question,
          item: {:ask, ask.id},
          raised_at: ask.asked_at,
          resolving: [
            # the agent's own suggested answers and its context ride on the
            # op (#450): a surface reads args back from the signal, so a
            # one-click reply is checked against what was actually offered
            op("Answer", :answer_ask, %{
              ask: ask.id,
              replies: Map.get(ask, :replies, []),
              context: Map.get(ask, :detail)
            }),
            op("Dismiss", :dismiss_ask, %{ask: ask.id}),
            op("Open agent", :open_agent, %{agent: view.id})
          ]
        )

      state(view) == :waiting_for_user or gate_kind(view) == "question" ->
        signal(view, :needs_answer, :high,
          # An agent parked on a question is a worse state of the world than
          # one that asked and carried on, so say which it is.
          headline: "asked you a question and stopped",
          detail: detail(view),
          raised_at: gate_opened_at(view),
          resolving: [
            op("Answer", :answer, %{agent: view.id}),
            op("Open agent", :open_agent, %{agent: view.id})
          ]
        )

      true ->
        nil
    end
  end

  defp approval(view, _context) do
    gate_action = get_in(view, [:gate, :action_id])
    live_action = Map.get(view, :live_action_id)

    cond do
      state(view) == :awaiting_permission and live_action_matches?(live_action, gate_action) ->
        action_id = live_action || gate_action

        signal(view, :approval, :high,
          headline:
            approval_headline(get_in(view, [:gate, :class]), get_in(view, [:gate, :risk])),
          detail: approval_detail(view),
          raised_at: gate_opened_at(view),
          item: action_id,
          resolving: [
            op("Approve", :approve, %{agent: view.id, action: action_id}),
            op("Reject", :reject, %{agent: view.id, action: action_id}),
            op("Open agent", :open_agent, %{agent: view.id})
          ]
        )

      gate_kind(view) == "approval" ->
        signal(view, :approval, :high,
          headline: "approval needs recovery",
          detail: approval_detail(view),
          raised_at: gate_opened_at(view),
          item: gate_action,
          resolving: [
            op("Requeue", :recover_gate, %{agent: view.id, action: gate_action}),
            op("Open agent", :open_agent, %{agent: view.id})
          ]
        )

      true ->
        nil
    end
  end

  # Hand-written resolver views from older callers omit live_action_id. A
  # production Fleet view always carries it, so only those compatibility
  # views fall back to the durable action id.
  defp live_action_matches?(nil, gate_action), do: is_binary(gate_action)
  defp live_action_matches?(live_action, nil), do: is_binary(live_action)
  defp live_action_matches?(live_action, gate_action), do: live_action == gate_action

  # The class the agent declared (#451), when it declared one: "ready_pr" and
  # "merge" are different asks, and the rail has room to say which.
  # Risk (#451) is only ever beside a class: it is read from a pull request,
  # and only a classed gate names one.
  defp approval_headline(class, risk) when is_binary(class) and is_binary(risk),
    do: "wants your approval (#{class}, #{risk} risk)"

  defp approval_headline(class, _risk) when is_binary(class), do: "wants your approval (#{class})"
  defp approval_headline(_none, _risk), do: "wants your approval"

  # What set the risk goes under what was asked, so "high" is never a bare
  # adjective: it is these paths.
  defp approval_detail(view) do
    risk =
      case get_in(view, [:gate, :risk_paths]) do
        [_path | _rest] = paths -> "risk: " <> Enum.join(paths, ", ")
        _none -> nil
      end

    [detail(view), risk, review_detail(Map.get(view, :gate))]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp review_detail(%{review: %{summary: summary, findings: findings, provider: provider}})
       when is_binary(summary) do
    rows = Enum.map(findings, &review_finding/1)
    Enum.join(["#{provider} review: #{summary}" | rows], "\n")
  end

  defp review_detail(%{review_state: state}) when is_binary(state),
    do: "cross-provider review: #{state}"

  defp review_detail(_gate), do: nil

  defp review_finding(finding) do
    citation =
      finding
      |> get_in(["evidence", "files"])
      |> List.wrap()
      |> Enum.map_join(", ", &"#{&1["path"]}:#{&1["lines"]}")

    suffix = if citation == "", do: "", else: " (#{citation})"
    "#{finding["severity"]}: #{finding["claim"]}#{suffix}"
  end

  # A red check on a PR the agent DISOWNED (#313). Nothing in the fleet will
  # touch it -- the agent looked, decided it was not its work, and recorded
  # that -- so the operator is the only one who can clear it. This is
  # design/000's "a failing check the crew has declared not theirs", which
  # design/007 could not honour because the declaration was only ever prose in
  # a panel.
  defp disowned_check(view, _context) do
    case Enum.filter(failing_prs(view), & &1.disowned?) do
      [] ->
        nil

      disowned ->
        signal(view, :disowned_check, :normal,
          headline: "#{numbers(disowned)} red, and not its work",
          detail: "the agent disowned #{pluralise(length(disowned), "it")}; nobody else will",
          item: {:prs, Enum.map(disowned, & &1.number)},
          raised_at: nil,
          resolving: [op("Inspect", :open_agent, %{agent: view.id})]
        )
    end
  end

  defp red_check(view, _context) do
    case Enum.reject(failing_prs(view), & &1.disowned?) do
      [] ->
        nil

      failing ->
        signal(view, :red_check, :normal,
          headline: "#{numbers(failing)} red on its open PRs",
          # the same shape the disowned signal carries, so a surface can show
          # which check is red on each one
          item: {:prs, Enum.map(failing, & &1.number)},
          # The overview cache cannot date a check result, so this signal has
          # no raised_at and ranks after any dated signal. Better than
          # inventing a timestamp that would then sort against real ones.
          raised_at: nil,
          resolving: [op("Inspect", :open_agent, %{agent: view.id})]
        )
    end
  end

  # A turn that fails for a reason no later beat can fix (#527). A logged-out
  # `claude` fails every turn, and the agent still reads `scheduled`: alive on
  # every page, doing nothing (#443). In `:needs_you`, and above a question or
  # a gate, because answering either only starts another turn that fails the
  # same way.
  #
  # `auth_failed` and `config_error` are facts about the host, so one failure
  # is enough. A crash or a refused cap can be one bad turn; those wait for a
  # second in a row.
  @immediate_turn_failures [:auth_failed, :config_error]

  defp turn_failing(view, _context) do
    case Map.get(view, :turn_failure) do
      %{category: category, failures: failures} = failure
      when category in @immediate_turn_failures or failures >= 2 ->
        signal(view, :turn_failing, :high,
          headline: TurnFailure.remedy(category),
          detail: turn_failure_detail(failure),
          item: {:turn_failure, turn_failure_item(failure)},
          raised_at: Map.get(failure, :since),
          resolving: [op("Inspect", :open_agent, %{agent: view.id})]
        )

      _none_or_a_blip ->
        nil
    end
  end

  # What the item pane shows: the classifier's verdict and the last failure's
  # own words, so the page never reads the feed for them.
  defp turn_failure_item(%{category: category, failures: failures} = failure) do
    %{
      category: category,
      failures: failures,
      retryable: TurnFailure.retryable?(category),
      detail: Map.get(failure, :detail)
    }
  end

  defp turn_failure_detail(%{category: category, failures: failures} = failure) do
    count = "#{failures} failed #{pluralise(failures, "turn")} (#{category})"
    Enum.join([count | List.wrap(Map.get(failure, :detail))], ": ")
  end

  # A sensor that fails every run used to look exactly like one with nothing
  # to report (#444), so a detection channel could be dark for days and read
  # as quiet. In `:watching`, not `:needs_you`: nothing is blocked on the
  # operator, the fleet has noticed that one of its eyes is shut.
  #
  # The streak's start is a real timestamp, so unlike a red check this signal
  # is dated and ranks oldest-first among its own kind.
  defp sensor_failing(view, context) do
    threshold = Map.get(context, :sensor_failure_threshold, @sensor_failure_threshold)

    view
    |> Map.get(:sensor_failures, [])
    |> Enum.filter(&(&1.failures >= threshold))
    |> Enum.sort_by(&{-&1.failures, &1.id})
    |> case do
      [] ->
        nil

      failing ->
        signal(view, :sensor_failing, :normal,
          headline: sensor_headline(failing),
          detail: Enum.map_join(failing, "\n", &sensor_line/1),
          item: {:sensors, Enum.map(failing, & &1.id)},
          raised_at: failing |> Enum.map(& &1.since) |> oldest(),
          resolving: [op("Inspect", :open_agent, %{agent: view.id})]
        )
    end
  end

  # The tile draws only the headline, so for the common case of one sensor it
  # carries the error too: "ci-redisctl has failed 3 runs: SAML enforcement"
  # says what to fix, and "a sensor is failing" says to go and find out.
  defp sensor_headline([one]) do
    "#{one.id} has failed #{one.failures} runs: #{String.slice(one.last_error, 0, 80)}"
  end

  defp sensor_headline(many) do
    "#{length(many)} sensors are failing: #{Enum.map_join(many, ", ", & &1.id)}"
  end

  defp sensor_line(sensor), do: "#{sensor.id} (#{sensor.failures} runs): #{sensor.last_error}"

  defp oldest(times) do
    times |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end)
  end

  # Named PRs rather than a bare count: "#400 red" tells the operator which
  # tab to open, and a count tells them to go and find out.
  defp numbers([one]), do: "##{one.number}"

  defp numbers(prs), do: Enum.map_join(prs, ", ", &"##{&1.number}")

  defp failing_prs(view), do: Map.get(view, :failing_prs, [])

  defp rail_hit(view, _context) do
    budget = Map.get(view, :budget)
    spend = Map.get(view, :spend_today, 0)

    if is_number(budget) and budget > 0 and spend / budget >= @rail_hit_ratio do
      signal(view, :rail_hit, :high,
        headline: "daily rail reached",
        detail: "spent #{format_usd(spend)} of #{format_usd(budget)}",
        resolving: [
          op("Raise the rail", :set_rail, %{agent: view.id}),
          op("Open agent", :open_agent, %{agent: view.id})
        ]
      )
    end
  end

  # Defined, deliberately unimplemented. See the moduledoc.
  defp stalled(_view, _context), do: nil

  defp working(view, context) do
    if state(view) == :running or Map.get(view, :running_since) do
      started = Map.get(view, :running_since)

      signal(view, :working, :low,
        headline: "a turn is running",
        detail: started && "started #{elapsed(started, context.now)} ago",
        raised_at: started,
        resolving: [op("Watch", :open_agent, %{agent: view.id})]
      )
    end
  end

  defp paused(view, _context) do
    if state(view) == :paused do
      signal(view, :paused, :low,
        headline: "paused",
        resolving: [op("Resume", :resume, %{agent: view.id})]
      )
    end
  end

  defp scheduled(view, _context) do
    if scheduled?(view) do
      signal(view, :scheduled, :low,
        headline: "next beat #{Map.get(view, :cron)}",
        item: next_beat(view),
        resolving: [op("Beat now", :beat, %{agent: view.id})]
      )
    end
  end

  defp quiet(view, _context) do
    signal(view, :quiet, :low,
      headline: "nothing found in window",
      resolving: [op("Beat now", :beat, %{agent: view.id})]
    )
  end

  # The time is carried, never worded here: "in 12m" is stale a minute later,
  # so a surface words it against its own clock at render.
  defp next_beat(view) do
    case Map.get(view, :next_beat_at) do
      %DateTime{} = at -> {:next_beat, at}
      _unknown -> nil
    end
  end

  # A cron of nil or "manual" is an agent that only runs when told to. It is
  # at rest, not scheduled, and the fleet page should collapse it.
  defp scheduled?(view) do
    case Map.get(view, :cron) do
      cron when is_binary(cron) and cron != "" and cron != "manual" -> true
      _none -> false
    end
  end

  defp signal(view, kind, urgency, fields) do
    struct!(
      %Signal{
        subject: view.id,
        kind: kind,
        group: group_of(kind),
        urgency: urgency,
        headline: Keyword.fetch!(fields, :headline)
      },
      Keyword.delete(fields, :headline)
    )
  end

  defp op(label, op, args), do: %{label: label, op: op, args: args}

  defp state(view), do: Map.get(view, :state)

  defp gate_kind(view), do: get_in(view, [:gate, :kind])

  defp gate_opened_at(view), do: get_in(view, [:gate, :opened_at])

  # The live status payload carries the question or the action description;
  # the gate row carries the same text durably. Prefer whichever is present.
  defp detail(view), do: get_in(view, [:gate, :detail]) || Map.get(view, :detail)

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  defp format_usd(amount) when is_number(amount) do
    "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)
  end

  defp elapsed(%DateTime{} = from, %DateTime{} = now) do
    case max(DateTime.diff(now, from), 0) do
      seconds when seconds < 60 -> "#{seconds}s"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds -> "#{div(seconds, 3600)}h"
    end
  end
end
