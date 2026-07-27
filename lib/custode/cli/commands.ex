defmodule Custode.CLI do
  @moduledoc """
  Shared rendering for the `mix custode` leaf commands (#45): each command
  is one operator MCP tool call through `Custode.CLI.Client`, printed for
  humans (or raw with `--json`).
  """

  alias Custode.CLI.Client

  @doc "Run one tool call and print it. Returns cheer's :ok / {:error, :run_failed}."
  def emit(tool, arguments, json?, render_fun) do
    case Client.call(tool, arguments) do
      {:ok, decoded} when json? ->
        Mix.shell().info(Jason.encode!(decoded, pretty: true))
        :ok

      {:ok, decoded} ->
        Mix.shell().info(render_fun.(decoded))
        :ok

      {:error, message} ->
        Mix.shell().error("error: #{message}")
        {:error, :run_failed}
    end
  end

  def clock(iso) when is_binary(iso), do: String.slice(iso, 11, 8)
  def clock(_other), do: "--:--:--"
end

defmodule Custode.CLI.Status do
  @moduledoc false
  use Cheer.Command

  command "status" do
    about("List the routines and each one's live state.")
    option(:json, type: :boolean, help: "Raw JSON instead of the table.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    Custode.CLI.emit("list_routines", %{}, args[:json] == true, fn %{"routines" => routines} ->
      Enum.map_join(routines, "\n", fn routine ->
        state = routine["status"] |> String.trim_leading(":")

        "#{String.pad_trailing(routine["id"], 16)} #{String.pad_trailing(state, 24)} #{routine["cron"]}"
      end)
    end)
  end
end

defmodule Custode.CLI.Gates do
  @moduledoc false
  use Cheer.Command

  command "gates" do
    about("Recent gates, newest first (open ones carry the action id to approve).")
    option(:status, type: :string, help: "Filter: open | resolved | requeued | orphaned.")
    option(:limit, type: :integer, help: "Max rows (default 20).")
    option(:json, type: :boolean, help: "Raw JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments =
      %{}
      |> then(&if args[:status], do: Map.put(&1, :status, args[:status]), else: &1)
      |> then(&if args[:limit], do: Map.put(&1, :limit, args[:limit]), else: &1)

    Custode.CLI.emit("list_gates", arguments, args[:json] == true, &render/1)
  end

  defp render(%{"gates" => []}), do: "(no gates)"

  defp render(%{"gates" => gates}) do
    Enum.map_join(gates, "\n", fn gate ->
      "#{String.pad_trailing(gate["status"], 9)} #{String.pad_trailing(gate["agent_id"], 14)} " <>
        "#{String.pad_trailing(gate["action_id"] || "-", 10)} #{String.slice(gate["detail"] || "", 0, 90)}"
    end)
  end
end

defmodule Custode.CLI.Asks do
  @moduledoc false
  use Cheer.Command

  command "asks" do
    about("Open questions from agents, oldest first. Nothing here is blocked on you.")
    option(:agent, type: :string, help: "Restrict to one agent.")
    option(:json, type: :boolean, help: "Raw JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = if args[:agent], do: %{agent_id: args[:agent]}, else: %{}
    Custode.CLI.emit("list_asks", arguments, args[:json] == true, &render/1)
  end

  defp render(%{"asks" => []}), do: "(no open questions)"

  defp render(%{"asks" => asks}) do
    Enum.map_join(asks, "\n", fn ask ->
      "#{String.pad_leading(to_string(ask["id"]), 5)}  " <>
        "#{String.pad_trailing(ask["agent_id"], 16)} #{String.slice(ask["question"], 0, 90)}"
    end)
  end
end

defmodule Custode.CLI.Answer do
  @moduledoc false
  use Cheer.Command

  command "answer" do
    about("Answer an agent's open question. Closes it and drops the answer in its inbox.")
    argument(:ask_id, required: true, help: "The ask id (see: mix custode asks).")
    argument(:answer, required: true, help: "Your answer.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = %{ask_id: String.to_integer(args[:ask_id]), answer: args[:answer]}
    Custode.CLI.emit("answer_ask", arguments, false, &render/1)
  end

  defp render(%{"agent_id" => agent_id}), do: "answered; #{agent_id} reads it on its next sweep"
  defp render(other), do: inspect(other)
end

defmodule Custode.CLI.Disowned do
  @moduledoc false
  use Cheer.Command

  command "disowned" do
    about("Pull requests the fleet says are not its work. Red checks here reach you.")
    option(:repo, type: :string, help: "Restrict to one repo.")
    option(:json, type: :boolean, help: "Raw JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = if args[:repo], do: %{repo: args[:repo]}, else: %{}
    Custode.CLI.emit("list_disowned", arguments, args[:json] == true, &render/1)
  end

  defp render(%{"disowned" => []}), do: "(nothing disowned)"

  defp render(%{"disowned" => rows}) do
    Enum.map_join(rows, "\n", fn row ->
      "#{String.pad_trailing(row["repo"], 28)} ##{String.pad_trailing(to_string(row["number"]), 6)} " <>
        "#{String.pad_trailing(row["disowned_by"], 16)} #{row["reason"] || ""}"
    end)
  end
end

defmodule Custode.CLI.Disown do
  @moduledoc false
  use Cheer.Command

  command "disown" do
    about("Declare a PR is nobody's work in the fleet, so its red checks reach you.")
    argument(:repo, required: true, help: ~s(the repo, as "owner/name"))
    argument(:number, required: true, help: "the pull request number")
    argument(:reason, help: "why it is not the fleet's, in one line")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments =
      %{repo: args[:repo], number: String.to_integer(args[:number])}
      |> then(&if args[:reason], do: Map.put(&1, :reason, args[:reason]), else: &1)

    Custode.CLI.emit("repo_disown_pr", arguments, false, &render/1)
  end

  defp render(%{"repo" => repo, "number" => number}),
    do: "#{repo}##{number} disowned; a red check there now reaches you"

  defp render(other), do: inspect(other)
end

defmodule Custode.CLI.Reclaim do
  @moduledoc false
  use Cheer.Command

  command "reclaim" do
    about("Undo a disownment: the PR is the fleet's work again.")
    argument(:repo, required: true, help: ~s(the repo, as "owner/name"))
    argument(:number, required: true, help: "the pull request number")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = %{repo: args[:repo], number: String.to_integer(args[:number])}
    Custode.CLI.emit("repo_reclaim_pr", arguments, false, &render/1)
  end

  defp render(%{"repo" => repo, "number" => number}),
    do: "#{repo}##{number} reclaimed; its red checks are the fleet's again"

  defp render(other), do: inspect(other)
end

defmodule Custode.CLI.Approve do
  @moduledoc false
  use Cheer.Command

  command "approve" do
    about("Approve an agent's pending action.")
    argument(:agent_id, required: true, help: "The gated agent.")
    argument(:action_id, required: true, help: "The action id (see: mix custode gates).")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = %{agent_id: args[:agent_id], action_id: args[:action_id]}
    Custode.CLI.emit("approve_action", arguments, false, &inspect/1)
  end
end

defmodule Custode.CLI.Reject do
  @moduledoc false
  use Cheer.Command

  command "reject" do
    about("Reject an agent's pending action.")
    argument(:agent_id, required: true, help: "The gated agent.")
    argument(:action_id, required: true, help: "The action id (see: mix custode gates).")
    argument(:reason, help: "Why (default: \"rejected from CLI\").")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = %{
      agent_id: args[:agent_id],
      action_id: args[:action_id],
      reason: args[:reason] || "rejected from CLI"
    }

    Custode.CLI.emit("reject_action", arguments, false, &inspect/1)
  end
end

defmodule Custode.CLI.Beat do
  @moduledoc false
  use Cheer.Command

  command "beat" do
    about("Fire one sweep of a routine now (boots it if offline).")
    argument(:agent_id, required: true, help: "The routine to beat.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    Custode.CLI.emit("beat", %{agent_id: args[:agent_id]}, false, fn reply ->
      "beat scheduled (job #{reply["job_id"]})"
    end)
  end
end

defmodule Custode.CLI.Note do
  @moduledoc false
  use Cheer.Command

  command "note" do
    about("Drop an inbox note through the funnel (wakes the routine).")
    argument(:agent_id, required: true, help: "The routine whose inbox gets the note.")
    argument(:content, required: true, help: "The note body (markdown).")
    option(:name, type: :string, help: "Note filename (timestamped default).")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments =
      %{agent_id: args[:agent_id], content: args[:content]}
      |> then(&if args[:name], do: Map.put(&1, :name, args[:name]), else: &1)

    Custode.CLI.emit("drop_note", arguments, false, fn reply -> "dropped #{reply["path"]}" end)
  end
end

defmodule Custode.CLI.Feed do
  @moduledoc false
  use Cheer.Command

  command "feed" do
    about("The last N feed entries, oldest first.")
    option(:n, type: :integer, help: "How many (default 20).")
    option(:agent, type: :string, help: "Restrict to one agent.")
    option(:json, type: :boolean, help: "Raw JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments =
      %{}
      |> then(&if args[:n], do: Map.put(&1, :n, args[:n]), else: &1)
      |> then(&if args[:agent], do: Map.put(&1, :agent_id, args[:agent]), else: &1)

    Custode.CLI.emit("feed_tail", arguments, args[:json] == true, fn %{"entries" => entries} ->
      Enum.map_join(entries, "\n", fn entry ->
        text =
          entry["summary"] || entry["action"] || entry["question"] || entry["kind"] || ""

        "#{Custode.CLI.clock(entry["at"])} #{String.pad_trailing(entry["agent"] || "?", 14)} " <>
          "#{String.pad_trailing(entry["event"], 15)} #{String.slice(text, 0, 100)}"
      end)
    end)
  end
end

defmodule Custode.CLI.Spend do
  @moduledoc false
  use Cheer.Command

  command "spend" do
    about("Today's spend per routine (vs its daily rail) and the fleet total.")
    option(:json, type: :boolean, help: "Raw JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    Custode.CLI.emit("spend_today", %{}, args[:json] == true, &render/1)
  end

  defp render(reply) do
    rows = Enum.map_join(reply["routines"], "\n", &row/1)

    rows <>
      "\n\nfleet today $#{reply["fleet_today_usd"]}" <>
      tokens_suffix(reply["fleet_today_tokens"])
  end

  defp row(row) do
    rail = if row["daily_budget_usd"], do: " / $#{row["daily_budget_usd"]}", else: ""

    "#{String.pad_trailing(row["agent_id"], 16)} $#{row["today_usd"]}#{rail}" <>
      tokens_suffix(row["today_tokens"])
  end

  defp tokens_suffix(tokens) when is_integer(tokens) and tokens > 0, do: "  (#{tokens} tok)"
  defp tokens_suffix(_none), do: ""
end

defmodule Custode.CLI.Pause do
  @moduledoc false
  use Cheer.Command

  command "pause" do
    about("Emergency-pause an agent.")
    argument(:agent_id, required: true, help: "The agent to pause.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    Custode.CLI.emit("pause_agent", %{agent_id: args[:agent_id]}, false, fn reply ->
      "#{reply["agent_id"]} paused"
    end)
  end
end

defmodule Custode.CLI.Resume do
  @moduledoc false
  use Cheer.Command

  command "resume" do
    about("Resume a paused agent (the human override).")
    argument(:agent_id, required: true, help: "The agent to resume.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    Custode.CLI.emit("resume_agent", %{agent_id: args[:agent_id]}, false, fn reply ->
      "#{reply["agent_id"]} resumed"
    end)
  end
end

defmodule Custode.CLI.Drain do
  @moduledoc false
  use Cheer.Command

  command "drain" do
    about("Pause the queues, wait out executing turns, then stop the server.")

    long_about("""
    The graceful restart's first half (#132): pauses :ticks/:agents/:sensors
    immediately (closing the new-work race), replies with how many turns are
    still executing, and stops the VM when they finish. Progress lands in
    the feed. On --timeout expiry the queues STAY paused; resume_queue is
    the abort path.
    """)

    option(:timeout, type: :integer, help: "Give up (queues stay paused) after N ms.")
    option(:json, type: :boolean, help: "Raw JSON reply.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = if args[:timeout], do: %{timeout_ms: args[:timeout]}, else: %{}

    Custode.CLI.emit("drain", arguments, args[:json] == true, fn reply ->
      "draining: #{reply["executing"]} turn(s) executing\n#{reply["note"]}"
    end)
  end
end

defmodule Custode.CLI.Prompt do
  @moduledoc false
  use Cheer.Command

  command "prompt" do
    about("Send a prompt to an agent (also the answer path for a waiting question).")
    argument(:agent_id, required: true, help: "The agent to prompt.")
    argument(:text, required: true, help: "The prompt or answer text.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    arguments = %{agent_id: args[:agent_id], prompt: args[:text]}

    Custode.CLI.emit("prompt_agent", arguments, false, fn _reply -> "delivered" end)
  end
end

defmodule Custode.CLI.Away do
  @moduledoc false
  use Cheer.Command

  command "away" do
    about("Pin operator presence to AWAY: sweeps queue gates for morning instead of parking.")
  end

  @impl Cheer.Command
  def run(_args, _raw) do
    Custode.CLI.emit("set_presence", %{mode: "away"}, false, fn reply ->
      "presence pinned away (reading: #{reply["reading"]})"
    end)
  end
end

defmodule Custode.CLI.Back do
  @moduledoc false
  use Cheer.Command

  command "back" do
    about("Restore presence inference; the toggle itself counts as a fresh operator action.")
  end

  @impl Cheer.Command
  def run(_args, _raw) do
    Custode.CLI.emit("set_presence", %{mode: "auto"}, false, fn reply ->
      "presence back to inference (reading: #{reply["reading"]})"
    end)
  end
end
