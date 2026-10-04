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
  use Custode.MCP.Tool, name: "preview_routine"

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools
  alias Custode.Routine.Effort

  input_schema(%{
    "properties" => %{
      "agent" => %{
        "description" => "persona from the repo's .claude/agents/ (#19)",
        "type" => "string"
      },
      "cron" => %{
        "description" => "cron override (the profile usually supplies it)",
        "type" => "string"
      },
      "daily_budget_tokens" => %{"description" => "daily token rail", "type" => "integer"},
      "daily_budget_usd" => %{"description" => "daily budget rail", "type" => "number"},
      "effort" => %{"description" => "sweep effort override, e.g. \"low\"", "type" => "string"},
      "extra_allowed_tools" => %{
        "description" => "extra tool grants, e.g. [\"Bash(git log:*)\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "hermetic" => %{
        "description" => "seal out the repo's ambient CLAUDE.md/persona",
        "type" => "boolean"
      },
      "id" => %{"description" => "unique routine id", "type" => "string"},
      "max_budget_usd" => %{"description" => "per-turn budget rail", "type" => "number"},
      "max_turns" => %{"description" => "agentic turns per run", "type" => "integer"},
      "mcp" => %{"description" => "grant the custode MCP tools", "type" => "boolean"},
      "model" => %{"description" => "sweep model override, e.g. \"sonnet\"", "type" => "string"},
      "profile" => %{"description" => "profile name, e.g. \"backlog_worker\"", "type" => "string"},
      "prompt" => %{
        "description" => "sweep prompt (the profile usually supplies it)",
        "type" => "string"
      },
      "provider" => %{"description" => "agent provider: claude or codex", "type" => "string"},
      "repo" => %{"description" => "owner/name the routine serves", "type" => "string"},
      "role" => %{"description" => "role override, e.g. \"backlog_worker\"", "type" => "string"},
      "system_prompt_file" => %{
        "description" => "path to a standing-orders file",
        "type" => "string"
      },
      "tags" => %{
        "description" => "tags, e.g. [\"rust\", \"external\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "timeout_ms" => %{"description" => "per-turn subprocess timeout", "type" => "integer"},
      "working_dir" => %{"description" => "absolute path of the checkout", "type" => "string"},
      "workspace" => %{
        "description" => "notebook home (defaults to workspaces/<id>)",
        "type" => "string"
      }
    },
    "required" => ["id"],
    "type" => "object"
  })

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
  use Custode.MCP.Tool, name: "add_routine"

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  input_schema(%{
    "properties" => %{
      "agent" => %{
        "description" => "persona from the repo's .claude/agents/ (#19)",
        "type" => "string"
      },
      "cron" => %{
        "description" => "cron override (the profile usually supplies it)",
        "type" => "string"
      },
      "daily_budget_tokens" => %{"description" => "daily token rail", "type" => "integer"},
      "daily_budget_usd" => %{"description" => "daily budget rail", "type" => "number"},
      "effort" => %{"description" => "sweep effort override, e.g. \"low\"", "type" => "string"},
      "extra_allowed_tools" => %{
        "description" => "extra tool grants, e.g. [\"Bash(git log:*)\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "hermetic" => %{
        "description" => "seal out the repo's ambient CLAUDE.md/persona",
        "type" => "boolean"
      },
      "id" => %{"description" => "unique routine id", "type" => "string"},
      "max_budget_usd" => %{"description" => "per-turn budget rail", "type" => "number"},
      "max_turns" => %{"description" => "agentic turns per run", "type" => "integer"},
      "mcp" => %{"description" => "grant the custode MCP tools", "type" => "boolean"},
      "model" => %{"description" => "sweep model override, e.g. \"sonnet\"", "type" => "string"},
      "profile" => %{"description" => "profile name, e.g. \"backlog_worker\"", "type" => "string"},
      "prompt" => %{
        "description" => "sweep prompt (the profile usually supplies it)",
        "type" => "string"
      },
      "provider" => %{"description" => "agent provider: claude or codex", "type" => "string"},
      "repo" => %{"description" => "owner/name the routine serves", "type" => "string"},
      "role" => %{"description" => "role override, e.g. \"backlog_worker\"", "type" => "string"},
      "system_prompt_file" => %{
        "description" => "path to a standing-orders file",
        "type" => "string"
      },
      "tags" => %{
        "description" => "tags, e.g. [\"rust\", \"external\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "timeout_ms" => %{"description" => "per-turn subprocess timeout", "type" => "integer"},
      "working_dir" => %{"description" => "absolute path of the checkout", "type" => "string"},
      "workspace" => %{
        "description" => "notebook home (defaults to workspaces/<id>)",
        "type" => "string"
      }
    },
    "required" => ["id"],
    "type" => "object"
  })

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
  use Custode.MCP.Tool, name: "preview_routine_edit"

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  input_schema(%{
    "properties" => %{
      "agent" => %{
        "description" => "persona from the repo's .claude/agents/ (#19)",
        "type" => "string"
      },
      "cron" => %{"description" => "new cron override", "type" => "string"},
      "daily_budget_tokens" => %{"description" => "daily token rail", "type" => "integer"},
      "daily_budget_usd" => %{"description" => "new daily budget rail", "type" => "number"},
      "drop" => %{
        "description" => "override keys to REMOVE (profile serves again)",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "effort" => %{"description" => "new effort override, e.g. \"low\"", "type" => "string"},
      "extra_allowed_tools" => %{
        "description" => "extra tool grants, e.g. [\"Bash(git log:*)\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "hermetic" => %{
        "description" => "seal out the repo's ambient CLAUDE.md/persona",
        "type" => "boolean"
      },
      "id" => %{"description" => "routine id to edit", "type" => "string"},
      "max_budget_usd" => %{"description" => "new per-turn budget rail", "type" => "number"},
      "max_turns" => %{"description" => "new max turns", "type" => "integer"},
      "mcp" => %{"description" => "grant the custode MCP tools", "type" => "boolean"},
      "model" => %{"description" => "new model override, e.g. \"sonnet\"", "type" => "string"},
      "profile" => %{"description" => "new profile name", "type" => "string"},
      "prompt" => %{"description" => "new sweep prompt", "type" => "string"},
      "provider" => %{"description" => "new agent provider: claude or codex", "type" => "string"},
      "repo" => %{"description" => "new owner/name", "type" => "string"},
      "role" => %{"description" => "role override, e.g. \"backlog_worker\"", "type" => "string"},
      "system_prompt_file" => %{
        "description" => "path to a standing-orders file",
        "type" => "string"
      },
      "tags" => %{
        "description" => "replacement tag list",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "timeout_ms" => %{"description" => "new per-turn timeout", "type" => "integer"},
      "working_dir" => %{"description" => "new checkout path", "type" => "string"},
      "workspace" => %{"description" => "new notebook home", "type" => "string"}
    },
    "required" => ["id"],
    "type" => "object"
  })

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
  use Custode.MCP.Tool, name: "update_routine"

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  input_schema(%{
    "properties" => %{
      "agent" => %{
        "description" => "persona from the repo's .claude/agents/ (#19)",
        "type" => "string"
      },
      "cron" => %{"description" => "new cron override", "type" => "string"},
      "daily_budget_tokens" => %{"description" => "daily token rail", "type" => "integer"},
      "daily_budget_usd" => %{"description" => "new daily budget rail", "type" => "number"},
      "drop" => %{
        "description" => "override keys to REMOVE (profile serves again)",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "effort" => %{"description" => "new effort override, e.g. \"low\"", "type" => "string"},
      "extra_allowed_tools" => %{
        "description" => "extra tool grants, e.g. [\"Bash(git log:*)\"]",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "hermetic" => %{
        "description" => "seal out the repo's ambient CLAUDE.md/persona",
        "type" => "boolean"
      },
      "id" => %{"description" => "routine id to edit", "type" => "string"},
      "max_budget_usd" => %{"description" => "new per-turn budget rail", "type" => "number"},
      "max_turns" => %{"description" => "new max turns", "type" => "integer"},
      "mcp" => %{"description" => "grant the custode MCP tools", "type" => "boolean"},
      "model" => %{"description" => "new model override, e.g. \"sonnet\"", "type" => "string"},
      "profile" => %{"description" => "new profile name", "type" => "string"},
      "prompt" => %{"description" => "new sweep prompt", "type" => "string"},
      "provider" => %{"description" => "new agent provider: claude or codex", "type" => "string"},
      "repo" => %{"description" => "new owner/name", "type" => "string"},
      "role" => %{"description" => "role override, e.g. \"backlog_worker\"", "type" => "string"},
      "system_prompt_file" => %{
        "description" => "path to a standing-orders file",
        "type" => "string"
      },
      "tags" => %{
        "description" => "replacement tag list",
        "items" => %{"type" => "string"},
        "type" => "array"
      },
      "timeout_ms" => %{"description" => "new per-turn timeout", "type" => "integer"},
      "working_dir" => %{"description" => "new checkout path", "type" => "string"},
      "workspace" => %{"description" => "new notebook home", "type" => "string"}
    },
    "required" => ["id"],
    "type" => "object"
  })

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
  use Custode.MCP.Tool, name: "remove_routine"

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  input_schema(%{
    "properties" => %{"id" => %{"description" => "routine id to remove", "type" => "string"}},
    "required" => ["id"],
    "type" => "object"
  })

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
