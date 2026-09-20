defmodule CustodeWeb.Console.Item do
  @moduledoc """
  The console's item pane (#450): the subject's signal and what would clear
  it. Its controls are the signal's own `resolving` ops, so a new signal kind
  brings its buttons with it.
  """

  use Phoenix.Component

  import CustodeWeb.Components, only: [reject_form: 1]

  alias Custode.Operator.Actions
  alias Custode.Signal

  attr(:signal, :any, required: true)
  attr(:subject, :map, required: true)
  attr(:message_gen, :integer, required: true)

  def item(assigns) do
    assigns =
      assign(assigns, :ops, Enum.filter(assigns.signal.resolving, &Actions.handles?(&1.op)))

    ~H"""
    <h2 class="text-xs font-bold uppercase tracking-widest text-base-content/50">
      {if Signal.needs_you?(@signal), do: "needs you", else: "state"}
    </h2>
    <p class="mt-2 font-semibold">{@signal.headline}</p>
    <p :if={@signal.detail} class="mt-2 whitespace-pre-line text-sm text-base-content/70">
      {@signal.detail}
    </p>

    <.evidence item={@signal.item} repo={@subject.repo} />
    <.draft_batch :if={@subject.draft_batch} drafts={@subject.draft_batch} />

    <h3
      :if={@ops != []}
      class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50"
    >
      what you can do
    </h3>
    <div class="flex flex-wrap items-start gap-2">
      <.op :for={op <- @ops} op={op} message_gen={@message_gen} />
    </div>
    """
  end

  attr(:item, :any, required: true)
  attr(:repo, :string, default: nil)

  # What the signal points at, as something to click. On the live fleet
  # "main is red" arrived with no way to see what was red.
  def evidence(%{item: {:branch, branch}, repo: repo} = assigns) when is_binary(repo) do
    assigns = assign(assigns, branch: branch)

    ~H"""
    <p class="mt-3 text-sm">
      <a href={runs_url(@repo, @branch)} target="_blank" rel="noopener" class="link">
        failing runs on {@branch}
      </a>
    </p>
    """
  end

  def evidence(%{item: {:prs, numbers}, repo: repo} = assigns) when is_binary(repo) do
    assigns = assign(assigns, numbers: numbers)

    ~H"""
    <p class="mt-3 flex flex-wrap gap-x-3 text-sm">
      <a
        :for={number <- @numbers}
        href={"https://github.com/#{@repo}/pull/#{number}"}
        target="_blank"
        rel="noopener"
        class="link font-mono"
      >
        #{number}
      </a>
    </p>
    """
  end

  def evidence(%{item: {:sensors, ids}} = assigns) do
    assigns = assign(assigns, ids: ids)

    ~H"""
    <p class="mt-3 flex flex-wrap gap-1">
      <span :for={id <- @ids} class="badge badge-outline badge-sm font-mono">{id}</span>
    </p>
    """
  end

  def evidence(assigns), do: ~H""

  defp runs_url(repo, branch),
    do:
      "https://github.com/#{repo}/actions?query=" <>
        URI.encode_www_form("branch:#{branch} is:failure")

  attr(:drafts, :list, required: true)

  # A gated batch of drafted issues (#215): prune it here, then approve below.
  # Only the kept entries file. This used to exist only on the agent page,
  # which is the part of #447 the inbox could not carry.
  defp draft_batch(assigns) do
    ~H"""
    <h3 class="mb-1 mt-6 text-xs font-bold uppercase tracking-widest text-warning">
      drafted issues: {Enum.count(@drafts, &(&1.status == "drafted"))} of {length(@drafts)} kept
    </h3>
    <p class="mb-2 text-xs text-base-content/50">drop what you do not want, then approve</p>
    <ul class="space-y-2">
      <li :for={draft <- @drafts} class="rounded bg-base-200/60 p-2 text-sm">
        <div class="flex items-start gap-2">
          <div class="min-w-0 flex-1">
            <span class={[
              "font-medium",
              draft.status == "dropped" && "text-base-content/40 line-through"
            ]}>
              {draft.title}
            </span>
            <span class="ml-1 font-mono text-xs text-base-content/40">{draft.repo}</span>
          </div>
          <button
            :if={draft.status == "drafted"}
            class="btn btn-ghost btn-xs"
            phx-click="drop_draft"
            phx-value-id={draft.id}
          >
            drop
          </button>
          <button
            :if={draft.status == "dropped"}
            class="btn btn-ghost btn-xs"
            phx-click="keep_draft"
            phx-value-id={draft.id}
          >
            keep
          </button>
        </div>
        <details :if={draft.body not in [nil, ""]} class="mt-1">
          <summary class="cursor-pointer text-xs text-base-content/50">evidence</summary>
          <pre class="mt-1 max-h-60 overflow-y-auto whitespace-pre-wrap text-xs">{draft.body}</pre>
        </details>
      </li>
    </ul>
    """
  end

  attr(:op, :map, required: true)
  attr(:message_gen, :integer, required: true)

  # A question is a conversation, so its control is a reply box (#301).
  defp op(%{op: %{op: kind}} = assigns) when kind in [:answer, :answer_ask] do
    ~H"""
    <form
      id={"reply-#{@op.op}-#{@message_gen}"}
      phx-submit="op"
      class="flex w-full flex-col gap-2"
    >
      <input type="hidden" name="op" value={@op.op} />
      <textarea
        name="text"
        rows="4"
        required
        class="textarea textarea-bordered w-full text-sm"
        placeholder="your answer..."
      ></textarea>
      <button type="submit" class="btn btn-primary btn-sm self-end">answer</button>
    </form>
    """
  end

  defp op(%{op: %{op: :reject}} = assigns) do
    ~H"""
    <.reject_form agent={@op.args.agent} action={@op.args.action} size="btn-sm" />
    """
  end

  defp op(assigns) do
    ~H"""
    <button
      class={["btn btn-sm", (@op.op == :approve && "btn-success") || "btn-outline"]}
      phx-click="op"
      phx-value-op={@op.op}
    >
      {String.downcase(@op.label)}
    </button>
    """
  end
end
