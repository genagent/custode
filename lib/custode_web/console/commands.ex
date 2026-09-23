defmodule CustodeWeb.Console.Commands do
  @moduledoc "Builds and searches the console's read-first command menu."

  alias Custode.Signal
  alias CustodeWeb.Console.Rail

  @destinations [
    {"go-console", "Console", "Fleet and subjects", "/console", "⌘K"},
    {"go-manager", "Custode manager", "Talk to the fleet caretaker", "/custode", "⇧⌘K"},
    {"go-inbox", "Inbox", "Questions and approvals", "/inbox", nil},
    {"go-repos", "Repositories", "Repository health", "/repos", nil},
    {"go-workflows", "Workflows", "Workflow runs and proposals", "/workflows", nil},
    {"go-metrics", "Metrics", "Usage and fleet metrics", "/metrics", nil}
  ]

  def all(signals, selected) when is_list(signals) do
    destinations() ++
      subjects(signals) ++ attention(signals) ++ results() ++ actions(selected, signals)
  end

  def search(commands, query) when is_list(commands) do
    terms = query |> to_string() |> String.downcase() |> String.split(~r/\s+/, trim: true)

    commands
    |> Enum.filter(fn command -> Enum.all?(terms, &String.contains?(command.search, &1)) end)
    |> Enum.sort_by(&rank(&1, terms))
  end

  defp destinations do
    Enum.map(@destinations, fn {id, label, detail, path, shortcut} ->
      command(id, :destination, label, detail, path: path, shortcut: shortcut)
    end)
  end

  defp subjects(signals) do
    signals
    |> Enum.uniq_by(& &1.subject)
    |> Enum.map(fn signal ->
      routine = Custode.Routine.get(signal.subject)
      kind = if routine, do: "subject", else: "helper"
      detail = [kind, routine && routine.repo, signal.headline] |> compact(" · ")

      command("subject-#{signal.subject}", :subject, signal.subject, detail,
        path: Rail.subject_path(signal.subject)
      )
    end)
  end

  defp attention(signals) do
    signals
    |> Enum.filter(&Signal.needs_you?/1)
    |> Enum.map(fn signal ->
      command(
        "attention-#{signal.subject}",
        :attention,
        signal.headline,
        compact([signal.subject, signal.detail], " · "),
        path: Rail.subject_path(signal.subject)
      )
    end)
  end

  defp results do
    Custode.Feed.tail(40)
    |> Enum.reverse()
    |> Enum.filter(&(&1["event"] in ~w(turn turn_failed)))
    |> Enum.take(12)
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      label = entry["summary"] || entry["message"] || result_label(entry["event"])
      agent = entry["agent"] || "unknown"

      command("result-#{index}-#{agent}", :result, label, "#{agent} · #{entry["event"]}",
        path: Rail.subject_path(agent) <> "?tab=activity"
      )
    end)
  end

  defp actions(nil, _signals), do: [new_agent()]

  defp actions(selected, signals) do
    signal = Enum.find(signals, &(&1.subject == selected))
    routine = Custode.Routine.get(selected)
    state = subject_state(selected)

    cond do
      routine ->
        [new_agent(), beat(selected) | pause_or_resume(selected, state)]

      signal && state not in [:offline, :ended] ->
        [new_agent() | pause_or_resume(selected, state)]

      true ->
        [new_agent()]
    end
  end

  defp beat(selected),
    do:
      command("action-beat", :action, "Run #{selected} now", "Queues one scheduled beat",
        action: :beat
      )

  defp pause_or_resume(selected, :paused) do
    [
      command("action-resume", :action, "Resume #{selected}", "Restores scheduled work",
        action: :resume
      )
    ]
  end

  defp pause_or_resume(selected, _state) do
    [
      command("action-pause", :action, "Pause #{selected}", "Stops future scheduled work",
        action: :pause
      )
    ]
  end

  defp subject_state(selected) do
    case Custode.Agents.status(selected) do
      {:ok, status} -> Custode.state_of(status)
      {:error, _reason} -> :offline
    end
  end

  defp new_agent,
    do:
      command("action-new-agent", :action, "Add an agent", "Open guided setup",
        action: :new_agent
      )

  defp command(id, group, label, detail, opts) do
    %{
      id: id,
      group: group,
      label: label,
      detail: detail,
      path: opts[:path],
      action: opts[:action],
      shortcut: opts[:shortcut],
      search: [group, label, detail] |> compact(" ") |> String.downcase()
    }
  end

  defp compact(values, separator) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(separator, &to_string/1)
  end

  defp rank(command, []), do: {group_rank(command.group), command.label}

  defp rank(command, [first | _rest]) do
    label = String.downcase(command.label)
    prefix = if String.starts_with?(label, first), do: 0, else: 1
    {prefix, group_rank(command.group), command.label}
  end

  defp group_rank(:attention), do: 0
  defp group_rank(:subject), do: 1
  defp group_rank(:result), do: 2
  defp group_rank(:action), do: 3
  defp group_rank(:destination), do: 4

  defp result_label("turn_failed"), do: "Failed turn"
  defp result_label(_event), do: "Completed turn"
end
