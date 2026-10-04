defmodule CustodeWeb.Console.Item do
  @moduledoc """
  The console's item pane (#450): the subject's signal and what would clear
  it. Its controls are the signal's own `resolving` ops, so a new signal kind
  brings its buttons with it.
  """

  use Phoenix.Component

  import CustodeWeb.Components, only: [action_button: 1, ago: 1, foldable_text: 1, reject_form: 1]

  alias Custode.Operator.Actions
  alias Custode.Signal
  alias CustodeWeb.Components
  alias CustodeWeb.Console.Rail

  attr(:signal, :any, required: true)
  attr(:subject, :map, required: true)
  attr(:message_gen, :integer, required: true)
  attr(:next_up, :any, default: nil)
  attr(:checks, :map, default: %{})
  attr(:check_logs, :map, default: %{})

  def item(assigns) do
    assigns =
      assign(assigns, :ops, Enum.filter(assigns.signal.resolving, &Actions.handles?(&1.op)))

    ~H"""
    <h2 class="text-xs font-bold uppercase tracking-widest text-base-content/50">
      {if Signal.needs_you?(@signal), do: "needs you", else: "state"}
    </h2>
    <p class="mt-2 font-semibold">{@signal.headline}</p>
    <.foldable_text
      :if={@signal.detail}
      text={@signal.detail}
      class="mt-2 text-sm text-base-content/70"
    />
    <p :if={@signal.raised_at} class="mt-2 font-mono text-xs text-base-content/50">
      raised <.ago at={@signal.raised_at} />
    </p>

    <%!-- what the agent was doing when the question came up --%>
    <p
      :if={context(@signal)}
      id="ask-context"
      class="mt-3 whitespace-pre-line border-l-2 border-base-300 pl-3 text-sm text-base-content/60"
    >
      {context(@signal)}
    </p>

    <.evidence
      item={@signal.item}
      repo={@subject.repo}
      checks={@checks}
      check_logs={@check_logs}
    />
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

    <%!-- the next thing in the resolver's order, so a run of decisions is
          decide, click, decide. A link and never a jump: a page that moves
          after a click hides what the click did. --%>
    <p :if={@next_up} id="next-up" class="mt-8 border-t border-base-300 pt-4 text-sm">
      <span class="text-xs font-bold uppercase tracking-widest text-base-content/50">
        also needs you
      </span>
      <.link patch={Rail.subject_path(@next_up.subject)} class="mt-1 block hover:underline">
        <span class="block font-mono font-semibold">{@next_up.subject}</span>
        <span class="block text-base-content/60">{@next_up.headline} &rarr;</span>
      </.link>
    </p>
    """
  end

  attr(:signal, :any, required: true)
  attr(:message_gen, :integer, required: true)

  @doc "The selected signal's existing controls, embedded in a conversation exchange."
  def conversation_actions(assigns) do
    assigns =
      assign(assigns, :ops, Enum.filter(assigns.signal.resolving, &Actions.handles?(&1.op)))

    ~H"""
    <section
      :if={@ops != []}
      id="conversation-actions"
      class="mt-3 rounded-box border border-warning/40 bg-warning/5 p-4"
    >
      <p class="text-xs font-bold uppercase tracking-widest text-warning">needs you</p>
      <p class="mt-1 text-sm font-semibold">{@signal.headline}</p>
      <p
        :if={context(@signal)}
        class="mt-2 whitespace-pre-line border-l-2 border-base-300 pl-3 text-sm text-base-content/60"
      >
        {context(@signal)}
      </p>
      <div class="mt-3 flex flex-wrap items-start gap-2">
        <.op :for={op <- @ops} op={op} message_gen={@message_gen} />
      </div>
    </section>
    """
  end

  defp context(%Signal{resolving: resolving}) do
    Enum.find_value(resolving, fn
      %{op: :answer_ask, args: %{context: context}} when is_binary(context) and context != "" ->
        context

      _other ->
        nil
    end)
  end

  attr(:item, :any, required: true)
  attr(:repo, :string, default: nil)
  # `{repo, number} => {:ok, [check]} | {:error, reason}`, filled in by the
  # LiveView as GitHub answers; a missing key is a read still in flight
  attr(:checks, :map, default: %{})
  # `{repo, check_id} => {:ok, excerpt} | :unavailable`; missing means the
  # failed check's log read is still in flight
  attr(:check_logs, :map, default: %{})

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
    <div :for={number <- @numbers} class="mt-3 text-sm">
      <a
        href={"https://github.com/#{@repo}/pull/#{number}"}
        target="_blank"
        rel="noopener"
        class="link font-mono"
      >
        #{number}
      </a>
      <.checks
        result={Map.get(@checks, {@repo, number})}
        repo={@repo}
        check_logs={@check_logs}
      />
    </div>
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

  # The headline carries the cron; this is what the cron means right now.
  def evidence(%{item: {:next_beat, at}} = assigns) do
    assigns = assign(assigns, at: at)

    ~H"""
    <p class="mt-3 text-sm text-base-content/70" title={@at}>
      runs in <span class="font-mono">{Components.until_text(@at)}</span>
    </p>
    """
  end

  # Why the turn failed, in the failure's own words. Bounded: a stack trace
  # is evidence for the transcript, not for this pane.
  def evidence(%{item: {:turn_failure, failure}} = assigns) do
    assigns =
      assign(assigns,
        failure: failure,
        lines: failure.detail |> to_string() |> String.split("\n", trim: true) |> Enum.take(6)
      )

    ~H"""
    <div id="turn-failure" class="mt-3 text-sm">
      <p class="flex flex-wrap items-center gap-2">
        <span class="badge badge-outline badge-sm font-mono text-error">{@failure.category}</span>
        <span>
          {@failure.failures} failed {if @failure.failures == 1, do: "turn", else: "turns"} in a row
        </span>
        <span class="text-base-content/60">
          {if @failure.retryable, do: "retryable", else: "not retryable: the next beat fails the same way"}
        </span>
      </p>
      <pre
        :if={@lines != []}
        class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded border border-base-300 bg-base-200 p-2 font-mono text-xs"
      >{Enum.join(@lines, "\n")}</pre>
    </div>
    """
  end

  def evidence(assigns), do: ~H""

  attr(:result, :any, required: true)
  attr(:repo, :string, default: nil)
  attr(:check_logs, :map, default: %{})

  # Which check is red, not only that one is. Failed first, as returned by
  # `CustodeWeb.ConsoleLive`; each row links to its run, which is where the
  # log is.
  defp checks(%{result: {:ok, rows}} = assigns) do
    rows =
      Enum.map(rows, fn row ->
        excerpt =
          case Map.get(assigns.check_logs, {assigns.repo, row[:id]}) do
            {:ok, text} when is_binary(text) and text != "" -> text
            _other -> nil
          end

        Map.put(row, :excerpt, excerpt)
      end)

    assigns = assign(assigns, rows: rows)

    ~H"""
    <ul class="mt-1 divide-y divide-base-200 rounded-lg border border-base-300">
      <li :if={@rows == []} class="px-3 py-1.5 text-xs text-base-content/50">no check runs</li>
      <li :for={row <- @rows} class="px-3 py-1.5 font-mono text-xs">
        <div class="flex items-center gap-2">
          <span class={["inline-block size-2 shrink-0 rounded-full", check_tone(row)]}></span>
          <a
            :if={row[:url]}
            href={row.url}
            target="_blank"
            rel="noopener"
            class="link-hover truncate"
          >
            {row.name}
          </a>
          <span :if={!row[:url]} class="truncate">{row.name}</span>
          <span class="ml-auto shrink-0 text-base-content/50">{row.conclusion || row.status}</span>
        </div>
        <pre
          :if={row.excerpt}
          id={"check-log-#{row.id}"}
          class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap rounded border border-base-300 bg-base-200 p-2 text-xs text-base-content/70"
        >{row.excerpt}</pre>
      </li>
    </ul>
    """
  end

  defp checks(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, reason: reason)

    ~H"""
    <p class="mt-1 text-xs text-warning">checks unavailable: {@reason}</p>
    """
  end

  defp checks(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/40">reading checks...</p>
    """
  end

  defp check_tone(%{conclusion: conclusion}) when conclusion in ~w(failure timed_out cancelled),
    do: "bg-error"

  defp check_tone(%{conclusion: "success"}), do: "bg-success"
  defp check_tone(%{conclusion: nil}), do: "bg-warning"
  defp check_tone(_row), do: "bg-base-content/20"

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
          <.action_button
            :if={draft.status == "drafted"}
            variant={:quiet}
            phx-click="drop_draft"
            phx-value-id={draft.id}
          >
            Drop
          </.action_button>
          <.action_button
            :if={draft.status == "dropped"}
            variant={:quiet}
            phx-click="keep_draft"
            phx-value-id={draft.id}
          >
            Keep
          </.action_button>
        </div>
        <details :if={draft.body not in [nil, ""]} class="mt-1">
          <summary class="cursor-pointer text-xs text-base-content/50">Evidence</summary>
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
      <label for={"reply-text-#{@op.op}-#{@message_gen}"} class="text-sm font-medium">Your answer</label>
      <textarea
        id={"reply-text-#{@op.op}-#{@message_gen}"}
        name="text"
        rows="4"
        required
        class="textarea textarea-bordered w-full text-sm"
        aria-describedby={"reply-help-#{@op.op}-#{@message_gen}"}
      ></textarea>
      <p id={"reply-help-#{@op.op}-#{@message_gen}"} class="text-xs text-base-content/60">Send an answer to this question.</p>
      <.action_button type="submit" variant={:primary} class="self-end">Answer</.action_button>
    </form>
    <%!-- question-inline.png's "or just say": answers the agent said it would
          accept. The click sends an INDEX; the text is read back from the
          signal, so only what the agent offered can be sent this way. --%>
    <div :if={replies(@op) != []} id="suggested-replies" class="mt-4 w-full">
      <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
        or just say
      </h3>
      <button
        :for={{reply, index} <- Enum.with_index(replies(@op))}
        type="button"
        phx-click="reply"
        phx-value-index={index}
        class="mb-2 block w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-left text-sm hover:border-base-content/40"
      >
        {reply}
      </button>
    </div>
    """
  end

  # A dismissal sends no answer. Its own form makes a blank reply harmless.
  defp op(%{op: %{op: :dismiss_ask}} = assigns) do
    ~H"""
    <form
      id={"dismiss-ask-#{@op.args.ask}-#{@message_gen}"}
      phx-submit="op"
      class="flex w-full flex-wrap items-center gap-2"
    >
      <input type="hidden" name="op" value="dismiss_ask" />
      <input type="hidden" name="ask_id" value={@op.args.ask} />
      <div class="min-w-0 flex-1">
        <label for={"dismiss-reason-#{@op.args.ask}-#{@message_gen}"} class="mb-1 block text-sm font-medium">Reason for dismissal (optional)</label>
        <input
          id={"dismiss-reason-#{@op.args.ask}-#{@message_gen}"}
          name="reason"
          type="text"
          aria-describedby={"dismiss-help-#{@op.args.ask}-#{@message_gen}"}
          class="input input-bordered input-sm w-full"
        />
        <p id={"dismiss-help-#{@op.args.ask}-#{@message_gen}"} class="mt-1 text-xs text-base-content/60">Dismisses the question without sending an answer.</p>
      </div>
      <.action_button type="submit" variant={:quiet}>Dismiss</.action_button>
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
    <.action_button
      variant={if @op.op in [:approve, :recover_gate, :resume], do: :primary, else: :secondary}
      phx-click="op"
      phx-value-op={@op.op}
    >
      {@op.label}
    </.action_button>
    """
  end

  defp replies(%{args: %{replies: replies}}) when is_list(replies), do: replies
  defp replies(_op), do: []
end
