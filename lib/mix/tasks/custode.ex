defmodule Mix.Tasks.Custode do
  @shortdoc "Operate the running custode fleet: `mix custode <status|gates|approve|...>`."

  @moduledoc """
  #{@shortdoc}

  A [`cheer`](https://hexdocs.pm/cheer) command tree over the operator MCP
  tools (#33/#35), talking to the RUNNING custode server over loopback HTTP.
  The task never starts the custode app; if the server is down it says so
  and exits non-zero. Every invocation doubles as a live integration test of
  the MCP surface.

  ## Commands

      mix custode status                      # routines + live states
      mix custode gates [--status open]       # what is waiting on a human
      mix custode approve <agent> <action>    # approve a gate
      mix custode reject <agent> <action> [reason]
      mix custode dismiss <id> [reason]       # close an ask without sending an answer
      mix custode beat <agent>                # fire one sweep now
      mix custode note <agent> "<content>"    # drop an inbox note (wakes it)
      mix custode feed [-n 50] [--agent id]   # the activity feed
      mix custode spend                       # today's spend vs the rails
      mix custode pause <agent> / resume <agent>
      mix custode provision-checkout <agent> <owner/name>
      mix custode refresh-checkout <agent>

  `CUSTODE_MCP_PORT` overrides the port (default: the configured 6161).
  """

  use Cheer.MixTask

  command "custode" do
    about("Operate the running custode fleet from the command line.")
    subcommand_required(true)

    subcommand(Custode.CLI.Status)
    subcommand(Custode.CLI.CurrentRun)
    subcommand(Custode.CLI.Doctor)
    subcommand(Custode.CLI.Drain)
    subcommand(Custode.CLI.Attention)
    subcommand(Custode.CLI.Inbox)
    subcommand(Custode.CLI.Gates)
    subcommand(Custode.CLI.Asks)
    subcommand(Custode.CLI.Answer)
    subcommand(Custode.CLI.Dismiss)
    subcommand(Custode.CLI.Disowned)
    subcommand(Custode.CLI.Disown)
    subcommand(Custode.CLI.Reclaim)
    subcommand(Custode.CLI.Approve)
    subcommand(Custode.CLI.Reject)
    subcommand(Custode.CLI.Beat)
    subcommand(Custode.CLI.Prompt)
    subcommand(Custode.CLI.Note)
    subcommand(Custode.CLI.Feed)
    subcommand(Custode.CLI.Spend)
    subcommand(Custode.CLI.Pause)
    subcommand(Custode.CLI.Resume)
    subcommand(Custode.CLI.ProvisionCheckout)
    subcommand(Custode.CLI.RefreshCheckout)
    subcommand(Custode.CLI.Away)
    subcommand(Custode.CLI.Back)
  end

  @impl Mix.Task
  def run(argv) do
    {:ok, _apps} = Application.ensure_all_started(:req)

    case Cheer.run(__MODULE__, argv, prog: "mix custode") do
      {:error, :usage} -> exit({:shutdown, 2})
      {:error, :run_failed} -> exit({:shutdown, 1})
      _ok -> :ok
    end
  end
end
