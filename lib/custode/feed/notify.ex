defmodule Custode.Feed.Notify do
  @moduledoc """
  Human-facing notification dispatch behind one interface (#92 item 5):
  every entry goes to ntfy (which applies its own filter); entries flagged
  `notify: true` (needs a human NOW) also raise the macOS desktop
  notification. The feed store calls `dispatch/3`; nothing else needs to
  know there are two channels.
  """

  @doc "Fan an entry out: `entry` atom-keyed (pre-encode), `decoded` JSON-clean."
  def dispatch(entry, decoded, opts) do
    Custode.Ntfy.publish(decoded)
    if opts[:notify], do: desktop(entry)
    :ok
  end

  # Fire-and-forget so a slow notifier never blocks the agent process the
  # telemetry handler runs in. terminal-notifier (brew) is preferred: clicking
  # the notification deep-links to the agent's dashboard page, where
  # osascript's display notification can only focus Script Editor.
  #
  # The delivery is a seam (`:desktop_sink`, as `:ntfy_sink` is for the other
  # channel), so a test can assert that an event raises a notification, or
  # that it deliberately does not, without one appearing on a screen.
  defp desktop(entry) do
    if Application.get_env(:custode, :desktop_notifications, true) do
      {title, body} = banner(entry)
      message = %{title: title, body: body, url: dashboard_url(entry), agent: entry[:agent]}
      sink = Application.get_env(:custode, :desktop_sink, &__MODULE__.deliver/1)

      Task.Supervisor.start_child(Custode.TaskSupervisor, fn -> sink.(message) end)
    end

    :ok
  end

  @doc false
  def deliver(message) do
    if match?({:unix, :darwin}, :os.type()) do
      deliver_notification(message.title, message.body, message.url, message.agent)
    end

    :ok
  end

  @doc """
  The `{title, body}` a desktop notification shows for `entry`.

  `:summary` is a body source and the agent is optional (#447). The workflow
  events have no agent and say what happened in `:summary`, so without both
  the notification read "custode:  workflow_launch_proposed" over a body of
  the event name again.
  """
  @spec banner(map()) :: {String.t(), String.t()}
  def banner(entry) do
    body =
      entry[:action] || entry[:question] || entry[:summary] ||
        to_string(entry[:kind] || entry.event)

    title = Enum.join(["custode:", entry[:agent], entry.event] |> Enum.reject(&is_nil/1), " ")

    {title, body}
  end

  defp deliver_notification(title, body, url, agent) do
    case System.find_executable("terminal-notifier") do
      nil ->
        script =
          "display notification #{inspect(String.slice(body, 0, 140))} " <>
            "with title #{inspect(title)} sound name \"Glass\""

        System.cmd("osascript", ["-e", script], stderr_to_stdout: true)

      notifier ->
        args = [
          "-title",
          title,
          "-message",
          String.slice(body, 0, 240),
          "-open",
          url,
          "-sound",
          "Glass",
          "-group",
          "custode-#{agent}"
        ]

        System.cmd(notifier, args, stderr_to_stdout: true)
    end
  end

  defp dashboard_url(entry), do: Custode.Ntfy.dashboard_url(entry[:agent])
end
