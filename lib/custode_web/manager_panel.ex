defmodule CustodeWeb.ManagerPanel do
  @moduledoc "The caretaker's operational context alongside its durable conversation."

  use Phoenix.Component

  import CustodeWeb.Components,
    only: [action_button: 1, ago: 1, feed_entry: 1, markdown: 1, reject_form: 1]

  alias Custode.Attention.Fleet

  @also_try [
    "what needs me right now, and what can wait until tomorrow?",
    "pause everything except mdbook-lint until Monday",
    "which agents have not changed an outcome in 14 days?",
    "add a routine for a new repository, same role as git-spawn",
    "tell every backlog worker to stop opening docs-only PRs"
  ]
  @away_window_s 24 * 60 * 60
  @did_limit 12

  def quick_prompt?(sentence), do: sentence in @also_try

  def current_plan(nil), do: nil

  def current_plan(caretaker) do
    caretaker |> Custode.Gates.open_gates() |> Enum.find(&(&1.kind == "approval"))
  end

  def read(caretaker) do
    feed = if caretaker, do: caretaker |> Custode.Feed.for_agent(150) |> Enum.reverse(), else: []
    {since, since_words} = away_since()
    said = Custode.Feed.said(feed)
    said_set = MapSet.new(said)
    plan = current_plan(caretaker)

    %{
      plan: plan,
      recovery: recovery?(caretaker, plan),
      said:
        said |> Enum.reject(&(&1["event"] in ["needs_approval", "needs_input"])) |> Enum.take(3),
      did:
        feed
        |> Enum.reject(
          &(&1["event"] in ["sensor", "sensor_failed"] or MapSet.member?(said_set, &1))
        )
        |> Enum.filter(&after?(&1["at"], since))
        |> Enum.take(@did_limit),
      did_since: since_words,
      also_try: @also_try
    }
  end

  attr(:plan, :any, required: true)
  attr(:caretaker, :string, required: true)
  attr(:recovery, :boolean, default: false)

  def plan(assigns) do
    ~H"""
    <section :if={@plan} id="custode-will" class="mx-auto w-full max-w-3xl rounded-box border border-warning/40 bg-base-100 p-4">
      <h2 class="mb-2 text-sm font-semibold">custode will</h2>
      <.markdown text={@plan.detail || "(no detail recorded)"} />
      <div class="mt-3 flex flex-wrap items-start gap-3">
        <.action_button :if={not @recovery} type="button" variant={:primary} phx-click="do_it" phx-value-action={@plan.action_id}>
          Approve plan
        </.action_button>
        <.action_button :if={@recovery} type="button" variant={:primary} phx-click="recover_plan" phx-value-action={@plan.action_id}>
          Requeue for re-evaluation
        </.action_button>
        <.reject_form :if={not @recovery} agent={@caretaker} action={@plan.action_id} label="Cancel" />
        <span class="self-center text-xs text-base-content/50">raised <.ago at={@plan.inserted_at} /></span>
      </div>
    </section>
    """
  end

  defp recovery?(_caretaker, nil), do: false

  defp recovery?(caretaker, plan) do
    case Fleet.blocking_signal(caretaker) do
      %{resolving: resolving} ->
        Enum.any?(resolving, &(&1.op == :recover_gate && &1.args[:action] == plan.action_id))

      _none ->
        false
    end
  end

  attr(:context, :map, required: true)

  attr(:include_said, :boolean, default: true)

  def activity(assigns) do
    ~H"""
    <details id="manager-context" class="rounded-box border border-base-300 bg-base-100 p-4">
      <summary class="cursor-pointer text-sm font-semibold">Caretaker activity</summary>
      <section :if={@include_said && @context.said != []} id="custode-said" class="mt-4">
        <h2 class="mb-2 text-xs font-semibold text-base-content/60">custode said</h2>
        <div class="flex flex-col gap-2">
          <.feed_entry :for={entry <- @context.said} entry={entry} show_agent={false} />
        </div>
      </section>
      <section id="custode-did" class="mt-4">
        <h2 class="mb-2 text-xs font-semibold text-base-content/60">what custode did {@context.did_since}</h2>
        <p :if={@context.did == []} class="text-sm text-base-content/50">nothing but its sweeps</p>
        <div :for={entry <- @context.did} class="flex gap-4 py-1 text-sm">
          <span class="w-16 shrink-0 text-base-content/40"><.ago at={entry["at"]} /></span>
          <span class="min-w-0 break-words text-base-content/80">{entry["summary"] || entry["event"]}</span>
        </div>
      </section>
    </details>
    """
  end

  attr(:sentences, :list, required: true)

  def prompts(assigns) do
    ~H"""
    <details id="manager-prompts" class="text-sm">
      <summary class="cursor-pointer text-base-content/60">Also try</summary>
      <button :for={sentence <- @sentences} type="button" phx-click="try" phx-value-sentence={sentence} class="mt-2 block w-full rounded-box bg-base-200 px-3 py-2 text-left hover:bg-base-300">
        {sentence}
      </button>
    </details>
    """
  end

  defp after?(at, since) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> DateTime.compare(parsed, since) != :lt
      {:error, _reason} -> false
    end
  end

  defp after?(_at, _since), do: false

  defp away_since do
    case Custode.Presence.status() do
      {:away, %DateTime{} = at} -> {at, "while you were away"}
      _present -> {DateTime.add(DateTime.utc_now(), -@away_window_s, :second), "in the last day"}
    end
  end
end
