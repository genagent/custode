defmodule CustodeWeb.AgentLive do
  @moduledoc """
  Everything for one agent: full status and controls (prompt, answer,
  approve/reject, pause/resume, beat), the notebook (todos, journal),
  memories, its slice of the feed, and the machine's own event log.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  alias Custode.Config.Loader
  alias Custode.Config.WriteBack
  alias ObanClaude.Agent

  @image_types ~w(.png .jpg .jpeg .gif .webp)
  @max_image_bytes 10_000_000

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    {:ok,
     socket
     |> assign(id: id, prompt_ack: nil, prompt_gen: 0)
     |> assign(edit: %{open: false, params: %{}, raw: %{}, error: nil})
     |> allow_image_upload(:image)
     |> allow_image_upload(:answer_image)
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:repo_overview, repo}, socket) do
    if socket.assigns.repo == repo,
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("prompt", %{"text" => text}, socket), do: send_prompt(socket, text, :image)

  # the answer box is its own submit with its own upload: both forms are on
  # screen while an agent waits, and an image staged for one must not ride the
  # other's send (#180 slice 2)
  def handle_event("answer", %{"text" => text}, socket),
    do: send_prompt(socket, text, :answer_image)

  # live uploads need a change event on the form to auto-upload; nothing to do
  # here beyond letting the entry's own validation land in the assigns
  def handle_event("validate_prompt", _params, socket), do: {:noreply, socket}

  def handle_event("drop_image", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, upload_key(upload), ref)}
  end

  # The edit form (#174 slice 2). Prefilled from the RAW entry so saving
  # can never bake profile defaults into the file; params live in assigns
  # so a re-render never wipes typed fields (#176's lesson).
  def handle_event("edit_open", _params, socket) do
    case WriteBack.raw_entry(socket.assigns.id) do
      {:ok, raw} ->
        strings = edit_strings(raw)
        {:noreply, assign(socket, edit: %{open: true, params: strings, raw: strings, error: nil})}

      {:error, reason} ->
        {:noreply,
         assign(socket, edit: %{open: false, params: %{}, raw: %{}, error: inspect(reason)})}
    end
  end

  def handle_event("edit_close", _params, socket) do
    {:noreply, assign(socket, edit: %{open: false, params: %{}, raw: %{}, error: nil})}
  end

  def handle_event("edit_change", %{"routine" => params}, socket) do
    {:noreply, update(socket, :edit, &%{&1 | params: params})}
  end

  def handle_event("edit_save", %{"routine" => params}, socket) do
    edit = socket.assigns.edit

    with {:ok, changes} <- edit_changes(edit.raw, params),
         {:ok, _path} <- apply_edit(socket.assigns.id, changes) do
      note = if changes == %{}, do: "no changes", else: "saved -- live at the next minute"

      {:noreply,
       socket
       |> assign(edit: %{open: false, params: %{}, raw: %{}, error: nil})
       |> put_flash(:info, "#{socket.assigns.id}: #{note}")
       |> refresh()}
    else
      {:error, reason} ->
        {:noreply,
         update(socket, :edit, &%{&1 | params: params, error: "refused: #{inspect(reason)}"})}
    end
  end

  def handle_event("edit_remove", _params, socket) do
    case WriteBack.remove_routine(socket.assigns.id) do
      {:ok, _path} ->
        Custode.Feed.record(%{
          event: "repo_verb",
          agent: socket.assigns.id,
          summary:
            "remove_routine #{socket.assigns.id}: removed from the dashboard, notebook kept"
        })

        {:noreply,
         socket
         |> put_flash(:info, "#{socket.assigns.id} removed -- notebook and workspace kept")
         |> push_navigate(to: "/")}

      {:error, reason} ->
        {:noreply, update(socket, :edit, &%{&1 | error: "remove refused: #{inspect(reason)}"})}
    end
  end

  def handle_event("approve", %{"action" => action_id}, socket) do
    Agent.approve_action(socket.assigns.id, action_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"action" => action_id}, socket) do
    Custode.reject_with_note(socket.assigns.id, action_id, "rejected from dashboard")
    {:noreply, refresh(socket)}
  end

  def handle_event("pause", _params, socket) do
    Agent.emergency_pause(socket.assigns.id)
    {:noreply, refresh(socket)}
  end

  def handle_event("resume", _params, socket) do
    Agent.resume_agent(socket.assigns.id)
    {:noreply, refresh(socket)}
  end

  def handle_event("beat", _params, socket) do
    {:ok, _job} = Custode.beat(socket.assigns.id)
    {:noreply, socket}
  end

  def handle_event("todo_done", %{"todo" => todo_id}, socket) do
    Custode.Notebook.todo_complete(String.to_integer(todo_id))
    {:noreply, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:fleet}>
      <div class="mb-4 flex items-center gap-3">
        <h2 class="font-mono text-2xl font-bold">{@id}</h2>
        <.status_badge status={@status} />
        <span :if={@routine} class="font-mono text-xs text-base-content/50">{@routine.cron}</span>
        <div class="ml-auto flex gap-2">
          <button :if={@routine} class="btn btn-xs" phx-click="beat">beat</button>
          <button
            :if={@state not in [:offline, :ended, :paused]}
            class="btn btn-outline btn-error btn-xs"
            phx-click="pause"
          >
            pause
          </button>
          <button :if={@state == :paused} class="btn btn-outline btn-success btn-xs" phx-click="resume">
            resume
          </button>
        </div>
      </div>

      <div class="stats stats-horizontal mb-4 bg-base-100 shadow-sm">
        <div class="stat px-4 py-2">
          <div class="stat-title text-xs">today</div>
          <div class="stat-value text-lg">${usd(@spend_today)}</div>
          <div :if={@routine && @routine.daily_budget_usd} class="stat-desc">
            of ${usd(@routine.daily_budget_usd)}
            <progress
              class={[
                "progress w-16",
                budget_progress_class(@spend_today, @routine.daily_budget_usd)
              ]}
              value={@spend_today}
              max={@routine.daily_budget_usd}
            >
            </progress>
          </div>
        </div>
        <div :if={@tokens_today > 0} class="stat px-4 py-2">
          <div class="stat-title text-xs">tokens</div>
          <div class="stat-value text-lg">{tok(@tokens_today)}</div>
          <div class="stat-desc">throughput today</div>
        </div>
        <div :if={@info} class="stat px-4 py-2">
          <div class="stat-title text-xs">turns</div>
          <div class="stat-value text-lg">{@info.turns}</div>
          <div :if={@info.session_id} class="stat-desc font-mono">
            session {String.slice(@info.session_id, 0, 8)}
          </div>
        </div>
        <div :if={@routine} class="stat px-4 py-2">
          <div class="stat-title text-xs">workspace</div>
          <div class="stat-value truncate text-sm font-normal">{@routine.workspace}</div>
          <div :if={@repo} class="stat-desc font-mono">{@repo}</div>
        </div>
      </div>

      <p :if={@state == :offline} class="mb-4 text-sm text-base-content/50">
        offline -- the next beat starts it
      </p>
      <p :if={@state == :ended} class="mb-4 text-sm text-base-content/50">
        ended -- this was an ephemeral agent; its memory and activity trail
        persist below (ghost tiles keep it on the fleet page for
        {div(Application.get_env(:custode, :ghost_window_s, 3_600), 60)}m)
      </p>

      <details :if={@routine} class="collapse collapse-arrow mb-4 bg-base-100 shadow-sm">
        <summary class="collapse-title text-sm font-semibold text-base-content/70">
          about this agent
          <span class="text-xs font-normal text-base-content/50">
            {@routine.role} &middot; {@routine.model}{if @routine.effort, do: "/#{@routine.effort}"} &middot; {cadence_words(@routine.cron)}
          </span>
        </summary>
        <div class="collapse-content space-y-2 text-sm">
          <div class="flex justify-end">
            <button class="btn btn-ghost btn-xs" phx-click="edit_open">edit</button>
          </div>
          <div class="flex flex-wrap gap-x-6 gap-y-1 text-base-content/70">
            <span>role <b>{@routine.role}</b></span>
            <span>
              sweeps <b>{@routine.model}</b><span :if={@routine.effort}> at {@routine.effort} effort</span>
            </span>
            <span :if={@routine.approved_args["model"]}>
              approved work <b>{@routine.approved_args["model"]}</b><span :if={@routine.approved_args["effort"]}> at {@routine.approved_args["effort"]}</span>
            </span>
            <span>
              rails ${usd(@routine.max_budget_usd)}/turn<span :if={@routine.daily_budget_usd}>, ${usd(@routine.daily_budget_usd)}/day</span>
            </span>
            <span :if={@routine.tags != []}>
              tags
              <span :for={tag <- @routine.tags} class="badge badge-ghost badge-xs">{tag}</span>
            </span>
          </div>
          <p :if={@agent_sensors != []} class="text-base-content/70">
            fed by sensors:
            <span :for={sensor <- @agent_sensors} class="badge badge-outline badge-xs mr-1">
              {sensor.id} ({sensor.cron})
            </span>
          </p>
          <p :if={@policies != []} class="text-base-content/70">
            bound by policies: <span class="font-mono text-xs">{Enum.join(@policies, ", ")}</span>
          </p>
          <details class="mt-1">
            <summary class="cursor-pointer text-xs text-base-content/50">
              standing orders (the composed system prompt)
            </summary>
            <pre class="mt-2 max-h-80 overflow-y-auto whitespace-pre-wrap rounded bg-base-200 p-3 text-xs">{@routine.system_prompt}</pre>
          </details>
        </div>
      </details>

      <.edit_agent_modal :if={@routine} edit={@edit} id={@id} />

      <div :if={match?({:awaiting_permission, _}, @status)} class="alert alert-warning mb-4">
        <div class="flex-1">
          <p class="font-semibold">wants permission:</p>
          <p class="text-sm">{elem(@status, 1).description}</p>
          <p :if={@policies != []} class="mt-1 text-xs opacity-70">
            review against: {Enum.join(@policies, ", ")}
          </p>
        </div>
        <div class="flex gap-2">
          <button class="btn btn-success btn-sm" phx-click="approve" phx-value-action={elem(@status, 1).id}>
            approve
          </button>
          <button class="btn btn-ghost btn-sm" phx-click="reject" phx-value-action={elem(@status, 1).id}>
            reject
          </button>
        </div>
      </div>

      <div :if={match?({:waiting_for_user, _}, @status)} class="alert alert-info mb-4">
        <div class="w-full">
          <p class="font-semibold">asks: {elem(@status, 1)}</p>
          <form
            phx-submit="answer"
            phx-change="validate_prompt"
            class="mt-2"
            id={"answer-form-#{@prompt_gen}"}
          >
            <.image_chips upload={@uploads.answer_image} />
            <div class="flex items-end gap-2" phx-drop-target={@routine && @uploads.answer_image.ref}>
              <textarea
                name="text"
                rows="2"
                placeholder="your answer..."
                class="textarea textarea-sm flex-1 resize-y"
                autocomplete="off"
              ></textarea>
              <button class="btn btn-primary btn-sm">answer</button>
            </div>
            <.image_picker :if={@routine} upload={@uploads.answer_image} />
          </form>
        </div>
      </div>

      <form
        :if={@state not in [:offline, :ended, :paused]}
        phx-submit="prompt"
        phx-change="validate_prompt"
        class="mb-1"
        id={"prompt-form-#{@prompt_gen}"}
      >
        <.image_chips upload={@uploads.image} />
        <div class="flex items-end gap-2" phx-drop-target={@routine && @uploads.image.ref}>
          <textarea
            name="text"
            rows="2"
            placeholder={"prompt #{@id}..."}
            class="textarea textarea-sm flex-1 resize-y font-mono"
            autocomplete="off"
          ></textarea>
          <button class="btn btn-primary btn-sm">
            {if @state == :running, do: "queue", else: "send"}
          </button>
        </div>
        <.image_picker :if={@routine} upload={@uploads.image} />
      </form>
      <p :if={@prompt_ack} class="mb-4 text-xs text-base-content/50">{@prompt_ack}</p>
      <div :if={!@prompt_ack} class="mb-5"></div>

      <section :if={@repo} class="mb-6">
        <h3 class="mb-2 text-lg font-semibold text-base-content/70">
          repository
          <a href={"https://github.com/#{@repo}"} target="_blank" class="link link-hover font-mono text-sm">
            {@repo}
          </a>
          <span :if={@repo_overview == :loading} class="loading loading-dots loading-xs ml-1"></span>
        </h3>
        <.repo_overview_panel overview={@repo_overview} />
      </section>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div class="space-y-6">
          <section :if={@routine}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">todo</h3>
            <p :if={@todos == []} class="text-sm text-base-content/40">(nothing open)</p>
            <ul class="space-y-1 text-sm">
              <li :for={todo <- @todos} class="flex items-center gap-2">
                <button
                  class="btn btn-ghost btn-xs"
                  title="mark done"
                  phx-click="todo_done"
                  phx-value-todo={todo.id}
                >
                  &#10003;
                </button>
                <span>{todo.text}</span>
              </li>
            </ul>
          </section>

          <section :if={@routine}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">journal</h3>
            <p :if={@journal == []} class="text-sm text-base-content/40">(no entries)</p>
            <div :for={entry <- @journal} class="mb-2 rounded-lg bg-base-100 p-3 text-sm shadow-sm">
              <p class="mb-1 text-xs text-base-content/50">
                <.ago at={entry.inserted_at} />
                <b :if={entry.title}>{entry.title}</b>
                <span class="text-base-content/40">({entry.source})</span>
              </p>
              <div :if={String.length(entry.body) <= 400}>
                <.markdown text={entry.body} />
              </div>
              <details
                :if={String.length(entry.body) > 400}
                class="collapse collapse-arrow rounded-none"
              >
                <summary class="collapse-title min-h-0 p-0 pr-8 text-sm text-base-content/80">
                  {String.slice(entry.body, 0, 200)}&hellip;
                </summary>
                <div class="collapse-content p-0">
                  <div class="mt-1"><.markdown text={entry.body} /></div>
                </div>
              </details>
            </div>
          </section>

          <section :if={@memories != []}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">memory</h3>
            <div :for={memory <- @memories} class="mb-1 text-sm">
              <span class="font-mono text-xs text-base-content/50">{memory.key}:</span>
              {memory.value}
            </div>
          </section>

          <section :if={@history != []}>
            <details class="collapse collapse-arrow bg-base-100 shadow-sm">
              <summary class="collapse-title text-lg font-semibold text-base-content/70">
                machine log <span class="text-xs font-normal">({length(@history)} events)</span>
              </summary>
              <div class="max-h-64 overflow-y-auto rounded-lg bg-base-100 p-3 font-mono text-xs shadow-sm">
                <p :for={entry <- @history} class="truncate text-base-content/70">
                  {inspect(entry, printable_limit: 160)}
                </p>
              </div>
            </details>
          </section>
        </div>

        <div>
          <h3 class="mb-2 text-lg font-semibold text-base-content/70">activity</h3>
          <p :if={@feed == []} class="text-sm text-base-content/40">(nothing yet)</p>
          <div class="space-y-2">
            <.feed_entry :for={entry <- Enum.reverse(@feed)} entry={entry} show_agent={false} />
          </div>
        </div>
      </div>
    </.page>
    """
  end

  # cast_prompt's real semantics, surfaced (#31): invisible queueing read as
  # "nothing happened" the first time the operator prompted a busy agent
  defp prompt_ack(:running), do: "queued -- delivers when the current turn ends"
  defp prompt_ack(:awaiting_permission), do: "queued behind the pending approval"
  defp prompt_ack(:waiting_for_user), do: "answer delivered"
  defp prompt_ack(_state), do: "sent -- turn starting"

  defp allow_image_upload(socket, name) do
    allow_upload(socket, name,
      accept: @image_types,
      max_entries: 1,
      max_file_size: @max_image_bytes
    )
  end

  defp send_prompt(socket, text, upload) do
    if String.trim(text) == "" and pending_images(socket, upload) == [] do
      {:noreply, socket}
    else
      # capture the state BEFORE casting: it decides what actually happens
      ack = prompt_ack(socket.assigns.state)
      composed = compose_prompt(socket, text, upload)
      Agent.cast_prompt(socket.assigns.id, composed)
      Custode.Feed.record_prompted(socket.assigns.id, composed)

      {:noreply,
       socket
       |> assign(prompt_ack: ack, prompt_gen: socket.assigns.prompt_gen + 1)
       |> refresh()}
    end
  end

  defp upload_key("answer_image"), do: :answer_image
  defp upload_key(_name), do: :image

  defp pending_images(socket, upload), do: socket.assigns.uploads[upload].entries

  # A dropped image reaches the agent as a path, not an attachment: claude
  # reads images natively through Read, and a file in the routine's own
  # workspace is already inside its readable world -- no wrapper or protocol
  # change at all (#180). The path is absolute because a routine's working_dir
  # is not always its workspace (a repo-tied routine runs in the checkout), and
  # a relative `uploads/` would not resolve from there.
  defp compose_prompt(socket, text, upload) do
    case save_images(socket, upload) do
      [] ->
        text

      paths ->
        [
          String.trim(text)
          | Enum.map(paths, &"attached image: #{&1} -- Read it before answering")
        ]
        |> Enum.join("\n")
        |> String.trim()
    end
  end

  defp save_images(%{assigns: %{routine: nil}}, _upload), do: []

  defp save_images(socket, upload) do
    dir = Path.join(Path.expand(socket.assigns.routine.workspace), "uploads")

    consume_uploaded_entries(socket, upload, fn %{path: path}, entry ->
      File.mkdir_p!(dir)
      dest = Path.join(dir, image_name(path, entry))
      File.cp!(path, dest)
      {:ok, dest}
    end)
  end

  # Content-hashed: the same screenshot dropped twice is one file, and a client
  # filename never steers the write.
  defp image_name(path, entry) do
    hash =
      :sha256
      |> :crypto.hash(File.read!(path))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    hash <> image_extension(entry)
  end

  defp image_extension(entry) do
    extension = entry.client_name |> Path.extname() |> String.downcase()
    if extension in @image_types, do: extension, else: ".png"
  end

  attr(:upload, :map, required: true)

  defp image_chips(assigns) do
    ~H"""
    <div :for={entry <- @upload.entries} class="mb-1 flex items-center gap-2 text-xs">
      <span class="badge badge-ghost badge-sm font-mono">{entry.client_name}</span>
      <progress :if={entry.progress < 100} class="progress w-16" value={entry.progress} max="100">
      </progress>
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="drop_image"
        phx-value-ref={entry.ref}
        phx-value-upload={@upload.name}
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
    """
  end

  attr(:upload, :map, required: true)

  defp image_picker(assigns) do
    ~H"""
    <label class="mt-1 flex items-center gap-2 text-xs text-base-content/40">
      <.live_file_input upload={@upload} class="file-input file-input-xs w-52" />
      or drop an image on the box
    </label>
    """
  end

  defp upload_error_text(:too_large), do: "too large (10MB max)"
  defp upload_error_text(:too_many_files), do: "one image at a time"
  defp upload_error_text(:not_accepted), do: "not an image"
  defp upload_error_text(error), do: to_string(error)

  attr(:edit, :map, required: true)
  attr(:id, :string, required: true)

  # The edit modal (#174 slice 2): raw values in, empty-a-field to drop that
  # override back to the profile. With no roster file yet, saving CREATES
  # routines.toml from the live roster -- the design 001 mode switch, said
  # out loud on the button rather than sprung on the operator.
  defp edit_agent_modal(assigns) do
    # target_path, not file_path: a set-but-absent CUSTODE_CONFIG raises in
    # file_path/0, but here it just means the first save creates the file
    assigns =
      assign(assigns, :migrates, not File.exists?(Loader.target_path()))

    ~H"""
    <dialog :if={@edit.open} class="modal modal-open" id="edit-agent-modal">
      <div class="modal-box max-w-2xl">
        <h3 class="mb-1 font-bold">edit {@id}</h3>
        <p class="mb-2 text-xs text-base-content/50">
          raw roster values: an empty field means the profile's default serves.
          Clearing a filled field drops that override.
        </p>
        <p :if={@migrates} class="mb-2 rounded bg-warning/20 p-2 text-xs">
          saving migrates your roster to <span class="font-mono">routines.toml</span>;
          the <span class="font-mono">config.exs</span> routine list will no longer apply.
        </p>
        <form phx-change="edit_change" phx-submit="edit_save">
          <div class="grid grid-cols-2 gap-2">
            <label :for={field <- @edit.params |> Map.keys() |> Enum.sort()} class="form-control">
              <span class="label-text text-xs font-mono">{field}</span>
              <input
                name={"routine[#{field}]"}
                value={@edit.params[field]}
                class="input input-bordered input-sm"
              />
            </label>
          </div>
          <p :if={@edit.error} class="mt-2 text-xs text-error">{@edit.error}</p>
          <div class="modal-action justify-between">
            <button
              type="button"
              class="btn btn-error btn-outline btn-sm"
              phx-click="edit_remove"
              data-confirm={"remove #{@id} from the roster? Its notebook and workspace are kept."}
            >
              remove agent
            </button>
            <div class="flex gap-2">
              <button type="button" class="btn btn-ghost btn-sm" phx-click="edit_close">
                cancel
              </button>
              <button class="btn btn-primary btn-sm">
                {if @migrates, do: "save (migrates roster to file)", else: "save"}
              </button>
            </div>
          </div>
        </form>
      </div>
    </dialog>
    """
  end

  @edit_fields ~w(agent cron model effort max_budget_usd daily_budget_usd timeout_ms max_turns prompt tags)

  # the raw entry's editable fields as form strings ("" = no override)
  defp edit_strings(raw) do
    Map.new(@edit_fields, fn field ->
      value =
        case Map.get(raw, String.to_existing_atom(field)) do
          nil -> ""
          :manual -> "manual"
          list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
          other -> to_string(other)
        end

      {field, value}
    end)
  end

  # submitted vs raw: same -> untouched; emptied an override -> nil (drop);
  # new non-empty value -> typed parse. The id never changes here.
  defp edit_changes(raw, params) do
    Enum.reduce_while(@edit_fields, {:ok, %{}}, fn field, {:ok, changes} ->
      submitted = String.trim(params[field] || "")
      original = String.trim(raw[field] || "")

      case edit_change(field, submitted, original) do
        :unchanged -> {:cont, {:ok, changes}}
        {:ok, value} -> {:cont, {:ok, Map.put(changes, String.to_existing_atom(field), value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp edit_change(_field, same, same), do: :unchanged
  defp edit_change(_field, "", _had_override), do: {:ok, nil}
  defp edit_change(field, submitted, _original), do: parse_edit_value(field, submitted)

  defp apply_edit(_id, changes) when changes == %{}, do: {:ok, :unchanged}
  defp apply_edit(id, changes), do: WriteBack.update_routine(id, changes)

  defp parse_edit_value(field, value) when field in ~w(agent cron model prompt), do: {:ok, value}

  defp parse_edit_value("effort", value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, "unknown effort #{inspect(value)}"}
  end

  defp parse_edit_value(field, value) when field in ~w(max_budget_usd daily_budget_usd) do
    case Float.parse(value) do
      {usd, ""} -> {:ok, usd}
      _other -> {:error, "#{field} must be a number, got #{inspect(value)}"}
    end
  end

  defp parse_edit_value(field, value) when field in ~w(timeout_ms max_turns) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _other -> {:error, "#{field} must be an integer, got #{inspect(value)}"}
    end
  end

  defp parse_edit_value("tags", value) do
    {:ok,
     value
     |> String.split(",")
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.map(&String.to_atom/1)}
  end

  defp refresh(socket) do
    id = socket.assigns.id
    routine = Custode.Routine.get(id)
    repo = routine && routine.repo
    {:ok, status} = Agent.status(id)
    status = resolve_status(status, routine, id)

    info =
      case Agent.info(id) do
        {:ok, info} -> info
        {:error, _reason} -> nil
      end

    history =
      case Agent.history(id) do
        {:ok, history} -> Enum.take(history, -20) |> Enum.reverse()
        {:error, _reason} -> []
      end

    assign(socket,
      routine: routine,
      policies: (routine && Custode.Policy.ids_for(routine)) || [],
      repo: repo,
      repo_overview: repo && repo_overview(repo),
      status: status,
      state: state_of(status),
      info: info,
      history: history,
      agent_sensors: Enum.filter(Custode.Routine.sensors(), &(&1.notify == id)),
      spend_today: Custode.SpendLedger.today(id),
      tokens_today: Custode.SpendLedger.today_tokens(id),
      todos: Custode.Notebook.todos(id),
      journal: Custode.Notebook.journal(id, 10),
      memories: Custode.Memory.recall(id),
      feed: Custode.Feed.for_agent(id, 30),
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  # A stopped agent with no routine but with a trail has ended, not gone
  # offline: offline means "the next beat starts it", which an ephemeral will
  # never get. This is the fleet page's ghost rule (#11) minus its display
  # window, so both pages say the same word about the same agent. An id with no
  # trail at all stays offline -- nothing has ended.
  defp resolve_status(:offline, nil, id) do
    if Custode.Feed.last_activity_at(id), do: :ended, else: :offline
  end

  defp resolve_status(status, _routine, _id), do: status

  defp state_of({state, _payload}), do: state
  defp state_of(state) when is_atom(state), do: state

  defp cadence_words("@daily"), do: "daily"
  defp cadence_words("@weekly"), do: "weekly"
  defp cadence_words("@hourly"), do: "hourly"
  defp cadence_words(:manual), do: "event-driven (no schedule)"
  defp cadence_words("*/" <> rest), do: "every #{rest |> String.split(" ") |> hd()}m"
  defp cadence_words(cron), do: to_string(cron)

  defp repo_overview(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} -> overview
      :loading -> :loading
    end
  end
end
