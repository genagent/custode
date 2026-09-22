defmodule CustodeWeb.Console.NewAgent do
  @moduledoc """
  The console's new-agent form (#450). Its conversions and the TOML preview
  are `Custode.Operator.RoutineNew`'s; this module only draws them.
  """

  use Phoenix.Component

  alias Custode.Operator.RoutineNew

  attr(:new_agent, :map, required: true)

  def new_agent_form(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold">new agent</h1>
    <p class="mt-1 text-sm text-base-content/60">
      A profile supplies the role, model, rails and prompt. Leave it empty for a bespoke agent
      and give it a prompt. Anything left blank is inherited, and everything is editable later.
    </p>

    <form id="new-routine" phx-change="new_change" phx-submit="new_create" class="mt-4">
      <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
        <label class="form-control">
          <span class="mb-1 font-mono text-xs text-base-content/60">id</span>
          <input
            type="text"
            name="routine[id]"
            value={@new_agent.params["id"]}
            required
            autocomplete="off"
            placeholder="my-repo"
            class="input input-bordered input-sm w-full font-mono"
          />
        </label>
        <label class="form-control">
          <span class="mb-1 font-mono text-xs text-base-content/60">provider</span>
          <select name="routine[provider]" class="select select-bordered select-sm w-full">
            <option value="claude" selected={@new_agent.params["provider"] in [nil, "", "claude"]}>
              claude
            </option>
            <option value="codex" selected={@new_agent.params["provider"] == "codex"}>codex</option>
          </select>
        </label>
        <label class="form-control">
          <span class="mb-1 font-mono text-xs text-base-content/60">profile</span>
          <select name="routine[profile]" class="select select-bordered select-sm w-full">
            <option value="">(none: bespoke)</option>
            <option
              :for={profile <- RoutineNew.profiles()}
              value={profile}
              selected={to_string(profile) == @new_agent.params["profile"]}
            >
              {profile}
            </option>
          </select>
        </label>
        <label :for={field <- ~w(repo working_dir tags cron)} class="form-control">
          <span class="mb-1 font-mono text-xs text-base-content/60">{field}</span>
          <input
            type="text"
            name={"routine[#{field}]"}
            value={@new_agent.params[field]}
            autocomplete="off"
            placeholder={new_placeholder(field)}
            class="input input-bordered input-sm w-full font-mono"
          />
        </label>
        <label class="form-control md:col-span-2">
          <span class="mb-1 font-mono text-xs text-base-content/60">prompt</span>
          <textarea
            name="routine[prompt]"
            rows="3"
            class="textarea textarea-bordered w-full text-sm"
            placeholder="only for a bespoke agent: what it does each sweep"
          >{@new_agent.params["prompt"]}</textarea>
        </label>
      </div>

      <p :if={@new_agent.error} class="mt-3 text-xs text-error">{@new_agent.error}</p>

      <div :if={@new_agent.preview} class="mt-4">
        <p class="mb-1 text-xs font-bold uppercase tracking-widest text-base-content/50">
          appended to the roster
        </p>
        <pre class="overflow-x-auto rounded bg-base-100 p-3 text-xs">{@new_agent.preview}</pre>
      </div>

      <div class="mt-4 flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">create</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="new_close">cancel</button>
      </div>
    </form>
    """
  end

  defp new_placeholder("repo"), do: "owner/name"
  defp new_placeholder("working_dir"), do: "/path/to/the/checkout"
  defp new_placeholder("tags"), do: "repo, rust"
  defp new_placeholder("cron"), do: "*/30 9-18 * * *"
end
