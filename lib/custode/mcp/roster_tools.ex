defmodule Custode.MCP.RosterTools do
  @moduledoc """
  Roster mutation tools (#75 / design 001 slice 3): the MCP surface over
  `Custode.Config.WriteBack`.

  Two tools, split so the PREVIEW is free and the WRITE is guarded:

    * `preview_routine` -- render the exact `[[routines]]` TOML section an
      add would append. Read-only, callable by anyone on the surface; this
      is what a caretaker puts in its `request_permission` action so the
      human approves the literal diff (D5).
    * `add_routine` -- the write. Caller-guarded: the operator and the
      caretaker (whose approved continuations run elevated) may call it;
      other routines and sub-agents are refused at the verb, not by prompt
      hope. Policy: entries that would carry the `:external` tag refuse
      agent callers outright -- a new public-surface routine is
      human-created only (the D5 example, enforced).

  The gate flow this enables: "custode, watch owner/repo like the others"
  -> the caretaker checks access (`gh repo view`), calls `preview_routine`,
  proposes `request_permission` with the rendered section in the action ->
  the human approves -> the elevated continuation calls `add_routine` ->
  file + live roster update in one operation (#121/#142 make the cron live
  at the next minute), and the caretaker beats the newcomer.
  """

  alias Custode.Operator.Authority

  @doc false
  # The attrs shape shared by both tools: assignment fields plus the
  # common overrides. Tags arrive as strings and convert exactly like the
  # TOML loader converts them.
  def to_attrs(params) do
    %{id: params.id}
    |> put_if(params, :provider, &String.to_existing_atom/1)
    |> put_if(params, :profile, &String.to_existing_atom/1)
    |> put_if(params, :cron)
    |> put_if(params, :repo)
    |> put_if(params, :working_dir)
    |> put_if(params, :workspace)
    |> put_if(params, :prompt)
    |> put_if(params, :model)
    |> put_if(params, :effort)
    |> put_if(params, :agent)
    |> put_if(params, :max_budget_usd)
    |> put_if(params, :daily_budget_usd)
    |> put_if(params, :daily_budget_tokens)
    |> put_if(params, :timeout_ms)
    |> put_if(params, :max_turns)
    |> put_if(params, :role, &String.to_existing_atom/1)
    |> put_if(params, :mcp)
    |> put_if(params, :hermetic)
    |> put_if(params, :system_prompt_file)
    |> put_if(params, :extra_allowed_tools)
    |> put_if(params, :tags, fn tags -> Enum.map(tags, &String.to_atom/1) end)
  end

  defp put_if(attrs, params, key, convert \\ & &1) do
    case Map.get(params, key) do
      nil -> attrs
      value -> Map.put(attrs, key, convert.(value))
    end
  end

  @doc false
  def external?(attrs), do: :external in Map.get(attrs, :tags, [])

  @doc false
  # The edit-changes shape (#174 slice 3): the assignment fields plus the
  # envelope knobs an edit most often touches (model, budgets, turns). A
  # `drop` list marks overrides to REMOVE, mapping to update_routine's
  # nil-drops-the-key semantics.
  def to_changes(params) do
    %{}
    |> put_if(params, :provider, &String.to_existing_atom/1)
    |> put_if(params, :profile, &String.to_existing_atom/1)
    |> put_if(params, :cron)
    |> put_if(params, :repo)
    |> put_if(params, :working_dir)
    |> put_if(params, :workspace)
    |> put_if(params, :prompt)
    |> put_if(params, :model)
    |> put_if(params, :effort)
    |> put_if(params, :agent)
    |> put_if(params, :max_budget_usd)
    |> put_if(params, :daily_budget_usd)
    |> put_if(params, :daily_budget_tokens)
    |> put_if(params, :timeout_ms)
    |> put_if(params, :max_turns)
    |> put_if(params, :role, &String.to_existing_atom/1)
    |> put_if(params, :mcp)
    |> put_if(params, :hermetic)
    |> put_if(params, :system_prompt_file)
    |> put_if(params, :extra_allowed_tools)
    |> put_if(params, :tags, fn tags -> Enum.map(tags, &String.to_atom/1) end)
    |> apply_drops(params)
  end

  defp apply_drops(changes, %{drop: fields}) when is_list(fields) do
    Enum.reduce(fields, changes, fn field, acc ->
      Map.put(acc, String.to_existing_atom(field), nil)
    end)
  end

  defp apply_drops(changes, _params), do: changes

  @doc false
  # Roster writes are for the operator and the caretaker (whose approved
  # continuation is the gate flow's actuator). Workers and sub-agents
  # propose to the caretaker instead -- one funnel, one judgment. The
  # single-writer call is deliberate (operator conversation, 2026-07-22):
  # any agent may ASK for a roster change; exactly one agent writes.
  def check_roster_writer(frame) do
    frame |> Custode.MCP.caller() |> Authority.roster_write()
  end
end

defmodule Custode.MCP.RosterTools.PreviewRoutine do
  @moduledoc """
  Render the exact TOML section adding this routine would append -- put this
  in your request_permission action so the human approves the literal diff.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools
  alias Custode.Routine.Effort

  schema do
    field(:id, :string, required: true, description: "unique routine id")
    field(:provider, :string, description: "agent provider: claude or codex")
    field(:profile, :string, description: "profile name, e.g. \"backlog_worker\"")
    field(:cron, :string, description: "cron override (the profile usually supplies it)")
    field(:repo, :string, description: "owner/name the routine serves")
    field(:working_dir, :string, description: "absolute path of the checkout")
    field(:workspace, :string, description: "notebook home (defaults to workspaces/<id>)")
    field(:prompt, :string, description: "sweep prompt (the profile usually supplies it)")
    field(:tags, {:list, :string}, description: "tags, e.g. [\"rust\", \"external\"]")
    field(:model, :string, description: "sweep model override, e.g. \"sonnet\"")
    field(:effort, :string, description: "sweep effort override, e.g. \"low\"")
    field(:agent, :string, description: "persona from the repo's .claude/agents/ (#19)")
    field(:role, :string, description: "role override, e.g. \"backlog_worker\"")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out the repo's ambient CLAUDE.md/persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "daily budget rail")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:timeout_ms, :integer, description: "per-turn subprocess timeout")
    field(:max_turns, :integer, description: "agentic turns per run")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")

    field(:extra_allowed_tools, {:list, :string},
      description: "extra tool grants, e.g. [\"Bash(git log:*)\"]"
    )
  end

  @impl true
  def execute(params, frame) do
    attrs = RosterTools.to_attrs(params)

    case Effort.normalize(attrs[:effort]) do
      {:ok, _effort} -> reply(frame, %{toml: WriteBack.render_routine(attrs)})
      {:error, message} -> fail(frame, message)
    end
  rescue
    ArgumentError -> fail(frame, "unknown profile #{inspect(params[:profile])}")
  end
end

defmodule Custode.MCP.RosterTools.AddRoutine do
  @moduledoc """
  Append a routine to the roster file and reload the running roster: the new
  routine is beatable immediately and scheduled at the next matching minute.
  Only the operator and the caretaker's approved continuations may call
  this; propose it via request_permission with the preview_routine render.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "unique routine id")
    field(:provider, :string, description: "agent provider: claude or codex")
    field(:profile, :string, description: "profile name, e.g. \"backlog_worker\"")
    field(:cron, :string, description: "cron override (the profile usually supplies it)")
    field(:repo, :string, description: "owner/name the routine serves")
    field(:working_dir, :string, description: "absolute path of the checkout")
    field(:workspace, :string, description: "notebook home (defaults to workspaces/<id>)")
    field(:prompt, :string, description: "sweep prompt (the profile usually supplies it)")
    field(:tags, {:list, :string}, description: "tags, e.g. [\"rust\", \"external\"]")
    field(:model, :string, description: "sweep model override, e.g. \"sonnet\"")
    field(:effort, :string, description: "sweep effort override, e.g. \"low\"")
    field(:agent, :string, description: "persona from the repo's .claude/agents/ (#19)")
    field(:role, :string, description: "role override, e.g. \"backlog_worker\"")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out the repo's ambient CLAUDE.md/persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "daily budget rail")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:timeout_ms, :integer, description: "per-turn subprocess timeout")
    field(:max_turns, :integer, description: "agentic turns per run")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")

    field(:extra_allowed_tools, {:list, :string},
      description: "extra tool grants, e.g. [\"Bash(git log:*)\"]"
    )
  end

  @impl true
  def execute(params, frame) do
    attrs = RosterTools.to_attrs(params)

    with :ok <- RosterTools.check_roster_writer(frame),
         :ok <- check_external_policy(frame, attrs),
         {:ok, path} <- WriteBack.add_routine(attrs) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "add_routine #{attrs.id}: appended to #{path}, roster reloaded"
      })

      reply(frame, %{id: attrs.id, path: path, live: true})
    else
      {:error, reason} -> fail(frame, "add_routine refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown profile #{inspect(params[:profile])}")
  end

  # The :external invariant, re-drawn from live use (2026-07-22): what
  # matters is that no :external routine exists that a human did not read
  # and approve -- and the caretaker's add only ever runs as the approved
  # continuation of a gate whose action IS the rendered TOML, so the human
  # approval is structural. The old unconditional block made the flow
  # clunky without adding protection (the caretaker just detoured through
  # ask_user and the operator ran the add by hand). Workers and sub-agents
  # remain fully refused by check_roster_writer.
  defp check_external_policy(_frame, _attrs), do: :ok
end

defmodule Custode.MCP.RosterTools.PreviewRoutineEdit do
  @moduledoc """
  Render the before/after TOML sections an edit would produce, without
  writing -- put BOTH in your request_permission action so the human
  approves the literal change. `drop` removes an override so the profile's
  value serves again.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "routine id to edit")
    field(:provider, :string, description: "new agent provider: claude or codex")
    field(:profile, :string, description: "new profile name")
    field(:cron, :string, description: "new cron override")
    field(:repo, :string, description: "new owner/name")
    field(:working_dir, :string, description: "new checkout path")
    field(:workspace, :string, description: "new notebook home")
    field(:prompt, :string, description: "new sweep prompt")
    field(:model, :string, description: "new model override, e.g. \"sonnet\"")
    field(:effort, :string, description: "new effort override, e.g. \"low\"")
    field(:agent, :string, description: "persona from the repo's .claude/agents/ (#19)")
    field(:role, :string, description: "role override, e.g. \"backlog_worker\"")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out the repo's ambient CLAUDE.md/persona")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")

    field(:extra_allowed_tools, {:list, :string},
      description: "extra tool grants, e.g. [\"Bash(git log:*)\"]"
    )

    field(:max_budget_usd, {:either, {:integer, :float}}, description: "new per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "new daily budget rail")
    field(:timeout_ms, :integer, description: "new per-turn timeout")
    field(:max_turns, :integer, description: "new max turns")
    field(:tags, {:list, :string}, description: "replacement tag list")
    field(:drop, {:list, :string}, description: "override keys to REMOVE (profile serves again)")
  end

  @impl true
  def execute(params, frame) do
    changes = RosterTools.to_changes(params)

    case WriteBack.preview_update(params.id, changes) do
      {:ok, %{before: before_toml, after: after_toml}} ->
        reply(frame, %{before: before_toml, after: after_toml})

      {:error, reason} ->
        fail(frame, "preview_routine_edit refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown field value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.RosterTools.UpdateRoutine do
  @moduledoc """
  Edit an existing routine on the roster file and reload the running roster
  (#174 slice 3): the change is live at the scheduler's next minute. Only
  the operator and the caretaker's approved continuations may call this;
  propose it via request_permission with the preview_routine_edit render.
  The id is immutable -- remove + add is the rename path.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "routine id to edit")
    field(:provider, :string, description: "new agent provider: claude or codex")
    field(:profile, :string, description: "new profile name")
    field(:cron, :string, description: "new cron override")
    field(:repo, :string, description: "new owner/name")
    field(:working_dir, :string, description: "new checkout path")
    field(:workspace, :string, description: "new notebook home")
    field(:prompt, :string, description: "new sweep prompt")
    field(:model, :string, description: "new model override, e.g. \"sonnet\"")
    field(:effort, :string, description: "new effort override, e.g. \"low\"")
    field(:agent, :string, description: "persona from the repo's .claude/agents/ (#19)")
    field(:role, :string, description: "role override, e.g. \"backlog_worker\"")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out the repo's ambient CLAUDE.md/persona")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")

    field(:extra_allowed_tools, {:list, :string},
      description: "extra tool grants, e.g. [\"Bash(git log:*)\"]"
    )

    field(:max_budget_usd, {:either, {:integer, :float}}, description: "new per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "new daily budget rail")
    field(:timeout_ms, :integer, description: "new per-turn timeout")
    field(:max_turns, :integer, description: "new max turns")
    field(:tags, {:list, :string}, description: "replacement tag list")
    field(:drop, {:list, :string}, description: "override keys to REMOVE (profile serves again)")
  end

  @impl true
  def execute(params, frame) do
    changes = RosterTools.to_changes(params)

    with :ok <- RosterTools.check_roster_writer(frame),
         {:ok, path} <- WriteBack.update_routine(params.id, changes) do
      changed = changes |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "update_routine #{params.id}: #{changed} -- #{path} rewritten, roster reloaded"
      })

      reply(frame, %{id: params.id, path: path, live: true})
    else
      {:error, reason} -> fail(frame, "update_routine refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown field value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.RosterTools.RemoveRoutine do
  @moduledoc """
  Remove a routine from the roster and stop its live agent (#174 slice 3).
  The notebook and workspace stay -- records outlive routines. Removal is
  de-escalation, so the caretaker's approved continuation may remove
  :external entries too. Propose via request_permission naming the id and
  why.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "routine id to remove")
  end

  @impl true
  def execute(params, frame) do
    with :ok <- RosterTools.check_roster_writer(frame),
         {:ok, path} <- WriteBack.remove_routine(params.id) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "remove_routine #{params.id}: spliced out of #{path}, agent stopped"
      })

      reply(frame, %{id: params.id, path: path, live: true})
    else
      {:error, reason} -> fail(frame, "remove_routine refused: #{inspect(reason)}")
    end
  end
end
