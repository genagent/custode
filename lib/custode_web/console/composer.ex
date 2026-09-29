defmodule CustodeWeb.Console.Composer do
  @moduledoc """
  The shared agent composer used by the control room and focused conversation.

  Drafts stay in browser `localStorage`, keyed by subject, through the
  `SubjectDraft` hook in the root layout. An accepted send clears that one
  draft; navigation between operator surfaces leaves it intact.
  """

  use Phoenix.Component

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
          remove
        </button>
        <span :for={error <- upload_errors(@upload, entry)} class="text-error">
          {upload_error_text(error)}
        </span>
      </div>
      <p :for={error <- upload_errors(@upload)} class="mb-1 text-xs text-error">
        {upload_error_text(error)}
      </p>

      <div class="flex flex-col gap-2 sm:flex-row" phx-drop-target={@routine && @upload.ref}>
        <textarea
          name="text"
          rows="2"
          data-draft-input
          class="textarea textarea-bordered w-full text-sm"
          placeholder={"message #{@subject_id}... #{message_hint(@state)}"}
        ></textarea>
        <button
          type="submit"
          class="btn btn-primary btn-sm self-end"
          phx-disable-with="sending..."
        >
          {message_label(@state)}
        </button>
      </div>

      <div class="mt-1 flex items-center gap-2 text-xs text-base-content/50">
        <span data-draft-state hidden>unsent draft saved in this browser</span>
        <button type="button" data-discard-draft hidden class="link">discard draft</button>
      </div>

      <label :if={@routine} class="mt-1 flex items-center gap-2 text-xs text-base-content/40">
        <.live_file_input upload={@upload} class="file-input file-input-xs w-52" />
        or drop an image on the box
      </label>
    </form>
    """
  end

  defp upload_error_text(:too_large), do: "too large (10MB max)"
  defp upload_error_text(:too_many_files), do: "one image at a time"
  defp upload_error_text(:not_accepted), do: "not an image type custode accepts"
  defp upload_error_text(other), do: to_string(other)

  defp message_label(:running), do: "queue"
  defp message_label(:waiting_for_user), do: "answer"
  defp message_label(:paused), do: "resume + send"
  defp message_label(:offline), do: "start + send"
  defp message_label(_state), do: "send"

  defp message_hint(:running), do: "(it is mid-turn: this queues)"
  defp message_hint(:paused), do: "(paused: sending resumes it)"
  defp message_hint(:offline), do: "(offline: this starts a turn with your message)"
  defp message_hint(:waiting_for_user), do: "(it is waiting on you: this is the answer)"
  defp message_hint(_state), do: ""
end
