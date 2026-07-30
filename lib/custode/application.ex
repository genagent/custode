defmodule Custode.Application do
  @moduledoc """
  The tree, bottom to top: repo -> migrations (Oban's tables) -> Oban (queues +
  the Cron plugin whose crontab carries the sensors and the janitor) ->
  `Custode.Scheduler` (routine firing, so cron edits are live without a
  restart, #142) -> the agent supervision tree -> nothing else.

  No agent is started here. Each routine's tick uses `if_offline: "start"`, so
  the schedule itself boots (and re-boots, after any restart) its agent.
  """

  use Application

  alias Custode.Feed
  alias Custode.Workflow

  @impl Application
  def start(_type, _args) do
    Custode.Observer.attach()
    Feed.Ingest.attach()
    Custode.PubSubBridge.attach()
    Custode.SpendLedger.attach()
    Custode.Gates.attach()
    Custode.SubAgents.attach()
    Custode.WorktreeBreadcrumb.attach()
    Custode.RunClock.attach()
    # name any prompt-asset override before the first sweep reads one (#269)
    Custode.Assets.report()
    Custode.Routine.ensure_workspaces!()

    children = [
      {Phoenix.PubSub, name: Custode.PubSub},
      # the in-flight clock (#211): owns its ETS table, so start it before
      # any run telemetry can fire
      Custode.RunClock,
      Custode.Repo,
      {Ecto.Migrator, repos: [Custode.Repo], log_migrations_sql: false},
      # single-instance guard (#77): claim the heartbeat row BEFORE Oban
      # starts. A boot that finds a live foreign instance refuses here, so
      # two servers never poll one db and double-run jobs during a restart's
      # graceful-shutdown overlap. CUSTODE_TAKEOVER=1 seizes a wedged one.
      Custode.Instance,
      Supervisor.child_spec({Task, &Custode.Missions.bootstrap!/0}, id: :mission_bootstrap),
      Supervisor.child_spec(
        {Task,
         fn ->
           Custode.LegacyMissionProjection.project_all!()
           Custode.LegacyRoleBindingProjection.project_all!()
         end},
        id: :legacy_scope_projection
      ),
      {Task.Supervisor, name: Custode.TaskSupervisor},
      {Oban, oban_config()},
      ObanClaude.Agent.Supervisor,
      # identity before configs: tokens are minted into the per-agent
      # config files the boot task writes next (#1/#2)
      Custode.MCP.Identity,
      Supervisor.child_spec({Task, &Custode.MCP.write_config!/0}, id: :mcp_configs),
      # repo panels: cached GitHub issue/PR overviews for repo-tied routines
      Custode.GitHub.Cache,
      # served repos (#10): one process per repo-tied project; verbs are calls
      Custode.Repository.Supervisor,
      # live check verdicts (#317): the two-tier read behind promoting a red
      # check to :needs_you. Starts after the Repository supervisor, since a
      # verification is a read verb on a served repo.
      Custode.Attention.Verify,
      # boot reconciliation: unresolved gates from before the restart become
      # RESTART NOTICE inbox notes the next sweep re-evaluates
      Supervisor.child_spec({Task, &Custode.Gates.reconcile!/0}, id: :gates_reconcile),
      # Expired workspace ownership becomes stale and retained. Reconciliation
      # never deletes a directory because expiry is not proof of ownership.
      Supervisor.child_spec({Task, &Custode.WorkspaceLeases.reconcile!/0},
        id: :workspace_leases_reconcile
      ),
      # A running Attempt whose lease or physical delivery was lost must not
      # leave its WorkItem active forever. Preserve the Attempt and its
      # provenance, record a typed worker-loss outcome, and block the WorkItem
      # for deterministic recovery.
      Supervisor.child_spec({Task, &Custode.AttemptPool.reconcile!/0},
        id: :attempt_worker_reconcile
      ),
      # orphaned sub-agents (#5) become revival-handle notices in their
      # parent's inbox -- offered, never auto-revived
      Supervisor.child_spec({Task, fn -> Custode.SubAgents.reconcile!() end},
        id: :sub_agents_reconcile
      ),
      # over-budget routines boot paused instead of leaking one turn (#6)
      Supervisor.child_spec({Task, &Custode.SpendLedger.reconcile_pauses!/0},
        id: :budget_reconcile
      ),
      # a workflow run whose last node landed while the app was down has
      # nothing to call it forward (#271). Slice 1b left this unwired on the
      # grounds that an enqueue-on-boot side effect belongs with the rail that
      # bounds it -- the rail is here now, and a budget_paused run is not
      # `running`, so this never restarts one the operator has not let go.
      Supervisor.child_spec({Task, fn -> Workflow.Runner.resume_all() end},
        id: :workflow_resume
      ),
      # start: true is load-bearing: anubis otherwise guesses whether to boot
      # its session machinery by sniffing for Phoenix config, and the
      # dashboard's endpoint config flips that guess to "no" -- which
      # silently breaks every MCP request with a missing session_config
      {Custode.MCP.Server, transport: {:streamable_http, start: true}},
      {Custode.MCP.MemoryServer, transport: {:streamable_http, start: true}},
      {Bandit, plug: Custode.MCP.Router, port: Custode.MCP.port(), ip: {127, 0, 0, 1}},
      # the ticks queue starts only after this loopback probe confirms the
      # MCP surface answers -- the first-sweep-after-restart tool blackout
      # (#4) was the claude CLI racing the session layer at boot
      Custode.MCP.Probe,
      # routine firing (#142): ticks once a minute, reads the roster fresh, and
      # inserts RoutineTick jobs -- so a cron edit is live next minute with no
      # restart. Starts after the Probe so its reboot inserts wait on the same
      # :ticks withhold (#4) a crontab insert would. autostart is off in test
      # (like the empty executing queues) so no timer fires a real insert; the
      # scheduler's own tests drive injected instances.
      {Custode.Scheduler, autostart: Application.get_env(:custode, :scheduler_autostart, true)},
      CustodeWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Custode.Supervisor)
  end

  defp oban_config do
    crontab = Custode.Routine.crontab()

    [
      repo: Custode.Repo,
      engine: Oban.Engines.Lite,
      notifier: Oban.Notifiers.PG,
      peer: Oban.Peers.Isolated,
      plugins: [
        {Oban.Plugins.Cron,
         crontab: crontab, timezone: Application.get_env(:custode, :timezone, "Etc/UTC")},
        # a crash mid-turn leaves the job row stuck executing; Lifeline
        # rescinds it so the durable-restart story holds for turns too.
        # MUST exceed the longest legitimate turn (backlog workers run
        # 900s + 60s watchdog): a shorter rescue_after re-runs a LIVE
        # turn's job -- double claude, double spend (audit 2026-07-21).
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)},
        # the jobs table is the audit trail: keep a week, not forever
        {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
      ],
      # ticks on their own queue so a beat observes the agent's state, not a
      # queue slot behind the agent's own turn job. Overridable so the test
      # env can run with no executing queues at all (no paid calls, ever).
      # agents: 3 so a routine turn, a one-shot job, and a sub-agent turn can
      # all run concurrently (a delegating parent occupies a slot while its
      # children need their own). :ticks is withheld here and started by
      # Custode.MCP.Probe once the MCP surface answers (#4).
      # workflows: 1 (#271, design/005) -- a deep dig runs its whole DAG on its
      # own queue at concurrency 1, so it is exactly as sequential as the rest
      # of the fleet and can never starve the sweeps. The DAG says what depends
      # on what; the queue says how many run at once, and raising this is a
      # per-machine knob rather than a structural change.
      queues:
        Application.get_env(:custode, :oban_queues,
          agents: 5,
          ticks: 1,
          sensors: 2,
          workflows: 1
        )
        |> Keyword.delete(:ticks)
    ]
  end
end
