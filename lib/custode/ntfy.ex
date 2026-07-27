defmodule Custode.Ntfy do
  @moduledoc """
  The custode feed on a phone (#13): every feed entry can publish to an
  [ntfy.sh](https://ntfy.sh) topic. Attention events (`needs_approval`,
  `needs_input`, `turn_failed`, `budget_paused`, `doctor_failed`, and the two
  workflow ones -- a launch gate waiting and a run parked on its rail) go out
  high-priority (they ring); ordinary turns and sensor lines go out
  min-priority (they accumulate silently in the app -- the feed, in your
  pocket). Tapping a notification opens the agent's dashboard page
  (pair with tailscale serve, #65, for links that work away from home).

  Disabled until a topic is configured:

      config :custode, ntfy: [
        topic: "custode-<long-random-suffix>",
        url: "https://ntfy.sh",       # or a self-hosted instance
        publish: :all                  # or :attention for alerts only
      ]

  ntfy.sh topics are public to anyone who guesses the name -- use a long
  random suffix or self-host. Publishing is fire-and-forget in a Task:
  a slow or down ntfy never blocks the telemetry path.
  """

  @attention ~w(needs_approval needs_input turn_failed budget_paused doctor_failed
                workflow_launch_proposed workflow_budget_paused)

  @doc "Publish one feed entry (string-keyed map) if ntfy is configured for it."
  def publish(entry) do
    topic = conf(:topic)
    urgent? = entry["event"] in @attention

    if is_binary(topic) and (urgent? or conf(:publish, :all) == :all) do
      message = build(entry, topic, urgent?)
      sink = sink()
      Task.Supervisor.start_child(Custode.TaskSupervisor, fn -> sink.(message) end)
    end

    :ok
  end

  @doc false
  def build(entry, topic, urgent?) do
    agent = entry["agent"] || "?"

    %{
      url: conf(:url, "https://ntfy.sh") <> "/" <> topic,
      title: "#{agent} #{entry["event"]}",
      body: text(entry),
      # ntfy priorities: 4 rings, 1 accumulates silently
      priority: if(urgent?, do: 4, else: 1),
      click: dashboard_url(agent)
    }
  end

  defp text(entry) do
    entry["summary"] || entry["action"] || entry["question"] || entry["kind"] || entry["event"]
  end

  @doc "The dashboard base URL (configurable so #65's ts.net links work)."
  def dashboard_url(agent) do
    base = Application.get_env(:custode, :dashboard_base_url, "http://localhost:4646")

    case agent do
      agent when is_binary(agent) and agent != "?" -> base <> "/agents/" <> agent
      _unknown -> base
    end
  end

  @doc false
  def deliver(message) do
    Req.post(message.url,
      body: message.body,
      headers: [
        {"title", message.title},
        {"priority", to_string(message.priority)},
        {"click", message.click}
      ],
      retry: false,
      receive_timeout: 10_000
    )

    :ok
  end

  defp sink, do: Application.get_env(:custode, :ntfy_sink, &__MODULE__.deliver/1)

  defp conf(key, default \\ nil) do
    Application.get_env(:custode, :ntfy, []) |> Keyword.get(key, default)
  end
end
