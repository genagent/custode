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
    Custode.MCP.write_config!()

    children = [
      {Phoenix.PubSub, name: Custode.PubSub},
      Custode.Repo,
      {Ecto.Migrator, repos: [Custode.Repo], log_migrations_sql: false},
      {Oban, oban_config()},
      ObanClaude.Agent.Supervisor,
      {Custode.MCP.Server, transport: :streamable_http},
      {Bandit, plug: Custode.MCP.Router, port: Custode.MCP.port(), ip: {127, 0, 0, 1}},
      CustodeWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Custode.Supervisor)
  end

  defp oban_config do
    crontab =
      for routine <- Custode.Routine.all() do
        {routine.cron, ObanClaude.Agent.Tick,
         args: Custode.Routine.tick_args(routine), queue: :ticks}
      end

    [
      repo: Custode.Repo,
      engine: Oban.Engines.Lite,
      notifier: Oban.Notifiers.PG,
      peer: Oban.Peers.Isolated,
      plugins: [{Oban.Plugins.Cron, crontab: crontab}],
      # ticks on their own queue so a beat observes the agent's state, not a
      # queue slot behind the agent's own turn job. Overridable so the test
      # env can run with no executing queues at all (no paid calls, ever).
      # agents: 3 so a routine turn, a one-shot job, and a sub-agent turn can
      # all run concurrently (a delegating parent occupies a slot while its
      # children need their own)
      queues: Application.get_env(:custode, :oban_queues, agents: 3, ticks: 1)
    ]
  end
end
