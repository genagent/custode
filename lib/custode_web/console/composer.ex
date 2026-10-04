defmodule CustodeWeb.Console.Composer do
  @moduledoc """
  The shared agent composer used by the control room and focused conversation.

  Drafts stay in browser `localStorage`, keyed by subject, through the
  `SubjectDraft` hook in the root layout. An accepted send clears that one
  draft; navigation between operator surfaces leaves it intact.
  """

  use Phoenix.Component

  import CustodeWeb.Components, only: [action_button: 1]

  attr(:subject_id, :string, required: true)
  attr(:state, :atom, required: true)
  attr(:routine, :any, default: nil)
  attr(:message_gen, :integer, required: true)
  attr(:upload, :map, required: true)
  attr(:class, :any, default: nil)

  def message_composer(assigns) do
    ~H"""
    <form
      id={"message-#{@message_gen}"}
      phx-hook="SubjectDraft"
      phx-submit="message"
      phx-change="validate_message"
      data-subject-draft
      data-subject={@subject_id}
      class={@class}
    >
      <div :for={entry <- @upload.entries} class="mb-1 flex items-center gap-2 text-xs">
        <span class="badge badge-ghost badge-sm font-mono">{entry.client_name}</span>
        <button
          type="button"
          class="link text-base-content/50"
          phx-click="drop_image"
          phx-value-ref={entry.ref}
        >
          Remove
        </button>
        <span :for={error <- upload_errors(@upload, entry)} class="text-error">
          {upload_error_text(error)}
        </span>
      </div>
      <p :for={error <- upload_errors(@upload)} class="mb-1 text-xs text-error">
        {upload_error_text(error)}
      </p>

      <label for={"message-input-#{@message_gen}"} class="mb-1 block text-sm font-medium">
        Message {@subject_id}
      </label>
      <div class="flex flex-col gap-2" phx-drop-target={@routine && @upload.ref}>
        <textarea
          id={"message-input-#{@message_gen}"}
          aria-describedby={"message-help-#{@message_gen}"}
          name="text"
          rows="2"
          data-draft-input
          class="textarea textarea-bordered w-full text-sm"
        ></textarea>
        <div data-composer-actions class="flex flex-wrap items-end justify-between gap-2">
          <label :if={@routine} class="flex min-w-0 max-w-full flex-col gap-1 text-xs text-base-content/70">
            Attach image
            <.live_file_input upload={@upload} class="file-input file-input-bordered file-input-sm w-full max-w-64 text-base-content" />
          </label>
          <.action_button
            type="submit"
            variant={:primary}
            class="ml-auto"
            phx-disable-with="Sending..."
          >
            {message_label(@state)}
          </.action_button>
        </div>
      </div>

      <p id={"message-help-#{@message_gen}"} class="mt-1 text-xs text-base-content/60">
        {message_hint(@state)}
      </p>
      <div class="mt-1 flex items-center gap-2 text-xs text-base-content/50">
        <span data-draft-state hidden>unsent draft saved in this browser</span>
        <button type="button" data-discard-draft hidden class="link">Discard draft</button>
      </div>

      <p :if={@routine} class="mt-1 text-xs text-base-content/60">You can also drop an image on the message box.</p>
    </form>
    """
  end

  defp upload_error_text(:too_large), do: "too large (10MB max)"
  defp upload_error_text(:too_many_files), do: "one image at a time"
  defp upload_error_text(:not_accepted), do: "not an image type custode accepts"
  defp upload_error_text(other), do: to_string(other)

  defp message_label(:running), do: "Queue message"
  defp message_label(:waiting_for_user), do: "Answer"
  defp message_label(:paused), do: "Resume and send"
  defp message_label(:offline), do: "Start and send"
  defp message_label(_state), do: "Send"

  defp message_hint(:running),
    do: "The agent is working. Your message will be queued after its current turn."

  defp message_hint(:paused), do: "Sending resumes this paused agent with your message."
  defp message_hint(:offline), do: "Sending starts a turn with your message."
  defp message_hint(:waiting_for_user), do: "The agent is waiting for your answer."
  defp message_hint(_state), do: "Send a message to continue this agent’s work."
end
