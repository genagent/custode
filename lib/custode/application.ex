defmodule Custode.Application do
  @moduledoc """
  The tree, bottom to top: repo -> migrations (Oban's tables) -> Oban (queues +
  the Cron plugin whose crontab carries one `ObanClaude.Agent.Tick` entry per
  configured routine) -> the agent supervision tree -> nothing else.

  No agent is started here. Each routine's tick uses `if_offline: "start"`, so
  the schedule itself boots (and re-boots, after any restart) its agent.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Custode.Observer.attach()
    Custode.Feed.attach()
    Custode.PubSubBridge.attach()
    Custode.SpendLedger.attach()
    Custode.Gates.attach()
    Custode.MCP.write_config!()
    Custode.Routine.ensure_workspaces!()

    children = [
      {Phoenix.PubSub, name: Custode.PubSub},
      Custode.Repo,
      {Ecto.Migrator, repos: [Custode.Repo], log_migrations_sql: false},
      {Oban, oban_config()},
      ObanClaude.Agent.Supervisor,
      # repo panels: cached GitHub issue/PR overviews for repo-tied routines
      Custode.GitHub.Cache,
      # boot reconciliation: unresolved gates from before the restart become
      # RESTART NOTICE inbox notes the next sweep re-evaluates
      Supervisor.child_spec({Task, &Custode.Gates.reconcile!/0}, id: :gates_reconcile),
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
        {Oban.Plugins.Cron, crontab: crontab},
        # a crash mid-turn leaves the job row stuck executing; Lifeline
        # rescinds it so the durable-restart story holds for turns too
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(10)},
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
      queues:
        Application.get_env(:custode, :oban_queues, agents: 3, ticks: 1, sensors: 2)
        |> Keyword.delete(:ticks)
    ]
  end
end
