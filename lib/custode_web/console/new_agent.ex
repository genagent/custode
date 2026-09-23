defmodule CustodeWeb.Console.NewAgent do
  @moduledoc "The console's shared first-agent and new-agent setup flow."

  use Phoenix.Component

  alias Custode.Operator.RoutineNew

  attr(:new_agent, :map, required: true)

  def new_agent_form(assigns) do
    ~H"""
    <div :if={@new_agent.choosing} id="first-agent-setup" class="max-w-4xl">
      <h1 class="text-2xl font-bold">choose your agent</h1>
      <p class="mt-2 font-semibold">No agents on this machine yet.</p>
      <p class="mt-1 text-sm text-base-content/60">
        The fleet caretaker is the recommended first agent. You can start with any supported
        shape, skip setup and return later, or copy <span class="font-mono">routines.example.toml</span>.
      </p>
      <div class="mt-5 grid grid-cols-1 gap-3 md:grid-cols-2">
        <button
          :for={shape <- RoutineNew.archetypes()}
          type="button"
          phx-click="new_kind"
          phx-value-kind={shape.id}
          class="card border border-base-300 bg-base-100 text-left shadow-sm hover:border-primary"
        >
          <span class="card-body gap-1 p-4">
            <span class="font-semibold">{shape.title}</span>
            <span class="text-xs text-base-content/60">{shape.description}</span>
            <span :if={shape.id == "caretaker"} class="badge badge-primary badge-sm mt-2">
              recommended
            </span>
          </span>
        </button>
      </div>
      <div class="mt-4 flex gap-2">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="new_skip">skip for now</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="new_close">cancel</button>
      </div>
    </div>

    <div :if={!@new_agent.choosing} class="max-w-4xl">
      <div class="flex items-start gap-3">
        <div>
          <h1 class="text-2xl font-bold">new agent</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Review the provider, cadence, and resolved capacity before creation. Profile defaults
            stay concise in the roster and remain editable later.
          </p>
        </div>
        <button type="button" class="btn btn-ghost btn-sm ml-auto" phx-click="new_choose">
          change type
        </button>
      </div>

      <form id="new-routine" phx-change="new_change" phx-submit="new_create" class="mt-4">
        <input type="hidden" name="routine[kind]" value={@new_agent.params["kind"]} />
        <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
          <.field label="id">
            <input type="text" name="routine[id]" value={@new_agent.params["id"]} required
              autocomplete="off" placeholder="my-agent"
              class="input input-bordered input-sm w-full font-mono" />
          </.field>
          <.field label="provider">
            <select name="routine[provider]" class="select select-bordered select-sm w-full">
              <option value="claude" selected={@new_agent.params["provider"] in [nil, "", "claude"]}>claude</option>
              <option value="codex" selected={@new_agent.params["provider"] == "codex"}>codex</option>
            </select>
          </.field>
          <.field label="profile">
            <select name="routine[profile]" class="select select-bordered select-sm w-full">
              <option value="">(none: bespoke)</option>
              <option :for={profile <- RoutineNew.profiles()} value={profile}
                selected={to_string(profile) == @new_agent.params["profile"]}>{profile}</option>
            </select>
          </.field>
          <.field label="cadence">
            <select name="routine[cadence]" class="select select-bordered select-sm w-full">
              <option :for={{value, label} <- RoutineNew.cadences()} value={value}
                selected={value == (@new_agent.params["cadence"] || "profile")}>
                {label}
              </option>
            </select>
            <span class="mt-1 text-xs text-base-content/50">
              {if (@new_agent.params["cadence"] || "profile") == "profile",
                do: RoutineNew.profile_cadence(@new_agent.params) <> " · ", else: ""}timezone: {RoutineNew.timezone()}
            </span>
          </.field>
          <.field :if={@new_agent.params["cadence"] == "custom"} label="custom cron">
            <input type="text" name="routine[cron]" value={@new_agent.params["cron"]}
              autocomplete="off" placeholder="*/30 9-18 * * 1-5"
              class="input input-bordered input-sm w-full font-mono" />
          </.field>

          <.field :if={RoutineNew.repository_available?(@new_agent.params)} label="repository">
            <input type="text" name="routine[repo]" value={@new_agent.params["repo"]}
              autocomplete="off" placeholder="owner/name"
              class="input input-bordered input-sm w-full font-mono" />
          </.field>

          <div :if={RoutineNew.repository_kind?(@new_agent.params)} class="md:col-span-2 rounded-lg border border-base-300 p-3">
            <span class="font-mono text-xs text-base-content/60">checkout on this Custode host</span>
            <div class="mt-2 flex flex-wrap gap-4 text-sm">
              <label class="label cursor-pointer gap-2 p-0">
                <input type="radio" name="routine[checkout_mode]" value="managed" class="radio radio-sm"
                  checked={@new_agent.params["checkout_mode"] in [nil, "", "managed"]} />
                <span><strong>managed clone</strong> <span class="text-base-content/50">recommended</span></span>
              </label>
              <label class="label cursor-pointer gap-2 p-0">
                <input type="radio" name="routine[checkout_mode]" value="existing" class="radio radio-sm"
                  checked={@new_agent.params["checkout_mode"] == "existing"} />
                <span>existing checkout</span>
              </label>
            </div>
            <div :if={@new_agent.params["checkout_mode"] == "existing"} class="mt-3 flex gap-2">
              <input type="text" name="routine[working_dir]" value={@new_agent.params["working_dir"]}
                autocomplete="off" placeholder="/absolute/path/on/the/custode/host"
                class="input input-bordered input-sm min-w-0 flex-1 font-mono" />
              <button type="button" class="btn btn-outline btn-sm" phx-click="new_browse">browse host</button>
            </div>
          </div>

          <.field label="model override">
            <input type="text" name="routine[model]" value={@new_agent.params["model"]}
              autocomplete="off" placeholder="profile default"
              class="input input-bordered input-sm w-full font-mono" />
          </.field>
          <.field label="effort override">
            <select name="routine[effort]" class="select select-bordered select-sm w-full">
              <option value="">profile default</option>
              <option :for={effort <- ~w(low medium high xhigh max ultra)} value={effort}
                selected={@new_agent.params["effort"] == effort}>{effort}</option>
            </select>
          </.field>
          <.field label="tags">
            <input type="text" name="routine[tags]" value={@new_agent.params["tags"]}
              autocomplete="off" placeholder="repo, rust"
              class="input input-bordered input-sm w-full font-mono" />
          </.field>
          <.field :if={RoutineNew.standing_prompt_available?(@new_agent.params)} label="standing prompt" class="md:col-span-2">
            <textarea name="routine[prompt]" rows="3" class="textarea textarea-bordered w-full text-sm"
              placeholder="What this agent owns and should do each sweep">{@new_agent.params["prompt"]}</textarea>
          </.field>
        </div>

        <p :if={@new_agent.error} class="mt-3 text-xs text-error">{@new_agent.error}</p>

        <div :if={@new_agent.browser} id="host-directory-browser" class="mt-4 rounded-lg border border-base-300 bg-base-100 p-3">
          <div class="flex items-center gap-2">
            <strong class="text-sm">directories on the Custode host</strong>
            <button type="button" class="btn btn-ghost btn-xs ml-auto" phx-click="new_browse_close">close</button>
          </div>
          <div class="mt-2 flex flex-wrap gap-1">
            <button :for={root <- @new_agent.browser.roots} type="button" class="btn btn-ghost btn-xs font-mono"
              phx-click="new_browse_dir" phx-value-path={root}>{root}</button>
          </div>
          <p class="mt-2 truncate font-mono text-xs">{@new_agent.browser.path}</p>
          <div class="mt-2 max-h-56 overflow-auto rounded bg-base-200 p-2">
            <button :if={@new_agent.browser.parent} type="button" class="block w-full rounded px-2 py-1 text-left font-mono text-xs hover:bg-base-300"
              phx-click="new_browse_dir" phx-value-path={@new_agent.browser.parent}>../</button>
            <button :for={path <- @new_agent.browser.directories} type="button"
              class="block w-full truncate rounded px-2 py-1 text-left font-mono text-xs hover:bg-base-300"
              phx-click="new_browse_dir" phx-value-path={path}>{Path.basename(path)}/</button>
          </div>
          <button type="button" class="btn btn-primary btn-sm mt-3" phx-click="new_browse_choose"
            phx-value-path={@new_agent.browser.path}>use this directory</button>
        </div>

        <div :if={@new_agent.plan} class="mt-4 grid gap-3 lg:grid-cols-2">
          <div>
            <p class="mb-1 text-xs font-bold uppercase tracking-widest text-base-content/50">appended to the roster</p>
            <pre class="overflow-x-auto rounded bg-base-100 p-3 text-xs">{@new_agent.plan.toml}</pre>
            <p :if={@new_agent.plan.effect} class="mt-2 rounded bg-info/10 p-2 text-xs text-info">{@new_agent.plan.effect}</p>
          </div>
          <div>
            <p class="mb-1 text-xs font-bold uppercase tracking-widest text-base-content/50">resolved agent</p>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 rounded bg-base-100 p-3 text-xs">
              <%= for {key, value} <- @new_agent.plan.resolved do %>
                <dt class="font-mono text-base-content/50">{key}</dt><dd>{inspect(value)}</dd>
              <% end %>
            </dl>
          </div>
        </div>

        <div class="mt-4 flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm" disabled={@new_agent.error != nil}>create</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="new_close">cancel</button>
        </div>
      </form>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp field(assigns) do
    ~H"""
    <label class={["form-control", @class]}>
      <span class="mb-1 font-mono text-xs text-base-content/60">{@label}</span>
      {render_slot(@inner_block)}
    </label>
    """
  end
end
