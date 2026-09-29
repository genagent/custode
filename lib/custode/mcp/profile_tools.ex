defmodule Custode.MCP.ProfileTools do
  @moduledoc """
  Profile mutation tools (#236): the MCP surface over the profile verbs of
  `Custode.Config.WriteBack`. The killer feature -- a human never *has* to
  hand-edit config, because the agent's tools cover the profile layer too --
  held tighter than the roster tools because a profile is where the
  dangerous grants live (a bypass_permissions approved_arg, extra Bash
  grants, the role).

  The split mirrors the roster tools: a FREE preview and a GUARDED write.

    * `preview_profile` / `preview_profile_edit` -- render the exact
      `[[profiles]]` TOML a define/edit would write, plus the DANGEROUS
      GRANTS it carries (the escalation flag). Read-only; this is what a
      caretaker puts in its request_permission action so the human approves
      the literal grants.
    * `define_profile` / `update_profile` / `remove_profile` -- the writes.
      Caretaker-only (`check_roster_writer`, the same single-writer gate the
      roster uses); workers and sub-agents are refused at the verb. Always
      gated, never auto: the grant surface is a privilege-escalation risk,
      so the human approves the rendered TOML every time.

  The approved_args surface is deliberately NARROW -- four explicit fields
  (`approve_bypass_permissions`, `approve_worktree`, `approve_model`,
  `approve_effort`) rather than a free map -- so a tool call cannot smuggle
  an arbitrary approved_arg past the gate; only the known wrapper vocabulary
  is expressible, and each shows up by name in the rendered TOML.
  """

  @doc false
  # Assemble a profile envelope from tool params. approved_args is built from
  # the four explicit approve_* fields, keeping the escalation surface
  # bounded and gate-legible.
  def to_envelope(params) do
    %{}
    |> put_if(params, :cron)
    |> put_if(params, :prompt)
    |> put_if(params, :role, &String.to_existing_atom/1)
    |> put_if(params, :provider, &String.to_existing_atom/1)
    |> put_if(params, :model)
    |> put_if(params, :effort)
    |> put_if(params, :agent)
    |> put_if(params, :workspace)
    |> put_if(params, :working_dir)
    |> put_if(params, :mcp)
    |> put_if(params, :hermetic)
    |> put_if(params, :max_budget_usd)
    |> put_if(params, :daily_budget_usd)
    |> put_if(params, :daily_budget_tokens)
    |> put_if(params, :timeout_ms)
    |> put_if(params, :max_turns)
    # Tags and sensor names are open vocabularies. Keep untrusted MCP values
    # as strings until the rendered TOML crosses the trusted loader boundary.
    |> put_if(params, :tags)
    |> put_if(params, :sensors)
    |> put_if(params, :system_prompt_file)
    |> put_if(params, :extra_allowed_tools)
    |> put_approved_args(params)
  end

  @doc false
  # Edit changes: the same fields, plus a `drop` list mapping to
  # update_profile's nil-drops-the-key semantics.
  def to_changes(params) do
    params |> to_envelope() |> apply_drops(params)
  end

  defp put_approved_args(envelope, params) do
    args =
      %{}
      |> maybe_arg(params, :approve_bypass_permissions, "permission_mode", fn true ->
        "bypass_permissions"
      end)
      |> maybe_arg(params, :approve_worktree, "worktree")
      |> maybe_arg(params, :approve_model, "model")
      |> maybe_arg(params, :approve_effort, "effort")

    if map_size(args) == 0, do: envelope, else: Map.put(envelope, :approved_args, args)
  end

  defp maybe_arg(args, params, field, key, convert \\ & &1) do
    case Map.get(params, field) do
      nil -> args
      false -> args
      value -> Map.put(args, key, convert.(value))
    end
  end

  defp put_if(envelope, params, key, convert \\ & &1) do
    case Map.get(params, key) do
      nil -> envelope
      value -> Map.put(envelope, key, convert.(value))
    end
  end

  defp apply_drops(changes, %{drop: fields}) when is_list(fields) do
    Enum.reduce(fields, changes, fn field, acc ->
      Map.put(acc, String.to_existing_atom(field), nil)
    end)
  end

  defp apply_drops(changes, _params), do: changes
end

defmodule Custode.MCP.ProfileTools.PreviewProfile do
  @moduledoc """
  Render the exact `[[profiles]]` TOML defining this profile would write,
  plus the dangerous grants it carries -- put this in your request_permission
  action so the human approves the literal grants (#236).
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.ProfileTools

  schema do
    field(:name, :string, required: true, description: "new profile name, e.g. \"reviewer\"")
    field(:cron, :string, description: "default cron for wearers, e.g. \"@daily\"")
    field(:prompt, :string, description: "default sweep prompt")
    field(:role, :string, description: "role, e.g. \"backlog_worker\" (which prompt/toolset)")
    field(:provider, :string, description: "agent provider: claude or codex")
    field(:model, :string, description: "sweep model, e.g. \"sonnet\"")
    field(:effort, :string, description: "sweep effort, e.g. \"low\"")
    field(:agent, :string, description: "persona from the repo's .claude/agents/")
    field(:workspace, :string, description: "notebook home template")
    field(:working_dir, :string, description: "checkout path template")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out the repo's ambient CLAUDE.md/persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "daily budget rail")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:timeout_ms, :integer, description: "per-turn subprocess timeout")
    field(:max_turns, :integer, description: "agentic turns per run")
    field(:tags, {:list, :string}, description: "tags every wearer inherits")
    field(:sensors, {:list, :string}, description: "sensors derived per wearer, e.g. [\"ci\"]")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")

    field(:extra_allowed_tools, {:list, :string},
      description: "GRANT: extra tools, e.g. [\"Bash(git log:*)\"] (a privilege surface)"
    )

    field(:approve_bypass_permissions, :boolean,
      description: "GRANT: approved continuations run with bypass_permissions"
    )

    field(:approve_worktree, :string,
      description: "approved-arg worktree template, e.g. \"custode-{id}\""
    )

    field(:approve_model, :string, description: "approved-arg model, e.g. \"opus\"")
    field(:approve_effort, :string, description: "approved-arg effort, e.g. \"high\"")
  end

  @impl true
  def execute(params, frame) do
    envelope = ProfileTools.to_envelope(params)

    case WriteBack.preview_new_profile(params.name, envelope) do
      {:ok, %{toml: toml, grants: grants}} -> reply(frame, %{toml: toml, grants: grants})
      {:error, reason} -> fail(frame, "preview_profile refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown role/effort value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.ProfileTools.PreviewProfileEdit do
  @moduledoc """
  Render the before/after `[[profiles]]` TOML an edit would produce, plus the
  dangerous grants the result carries -- put BOTH in your request_permission
  action so the human approves the literal change and sees the privilege
  surface it moves (#236). `drop` removes an envelope key.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.ProfileTools

  schema do
    field(:name, :string, required: true, description: "profile name to edit")
    field(:cron, :string, description: "new default cron")
    field(:prompt, :string, description: "new default sweep prompt")
    field(:role, :string, description: "new role")
    field(:provider, :string, description: "new agent provider: claude or codex")
    field(:model, :string, description: "new model")
    field(:effort, :string, description: "new effort")
    field(:agent, :string, description: "new persona")
    field(:workspace, :string, description: "new notebook home template")
    field(:working_dir, :string, description: "new checkout path template")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out ambient persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "new per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "new daily budget rail")
    field(:daily_budget_tokens, :integer, description: "new daily token rail")
    field(:timeout_ms, :integer, description: "new per-turn timeout")
    field(:max_turns, :integer, description: "new max turns")
    field(:tags, {:list, :string}, description: "replacement tag list")
    field(:sensors, {:list, :string}, description: "replacement sensor list")
    field(:system_prompt_file, :string, description: "path to a standing-orders file")
    field(:extra_allowed_tools, {:list, :string}, description: "GRANT: replacement tool list")

    field(:approve_bypass_permissions, :boolean,
      description: "GRANT: bypass_permissions on approval"
    )

    field(:approve_worktree, :string, description: "approved-arg worktree template")
    field(:approve_model, :string, description: "approved-arg model")
    field(:approve_effort, :string, description: "approved-arg effort")
    field(:drop, {:list, :string}, description: "envelope keys to REMOVE")
  end

  @impl true
  def execute(params, frame) do
    changes = ProfileTools.to_changes(params)

    case WriteBack.preview_profile(params.name, changes) do
      {:ok, %{before: before_toml, after: after_toml, grants: grants}} ->
        reply(frame, %{before: before_toml, after: after_toml, grants: grants})

      {:error, reason} ->
        fail(frame, "preview_profile_edit refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown role/effort value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.ProfileTools.DefineProfile do
  @moduledoc """
  Define a new profile in the roster file and reload, so routines can inherit
  it immediately -- no config.exs edit, no restart (#236). Only the operator
  and the caretaker's approved continuations may call this; propose it via
  request_permission with the preview_profile render so the human approves
  the exact grants. Never auto: a profile is a privilege-escalation surface.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.{ProfileTools, RosterTools}

  schema do
    field(:name, :string, required: true, description: "new profile name")
    field(:cron, :string, description: "default cron for wearers")
    field(:prompt, :string, description: "default sweep prompt")
    field(:role, :string, description: "role (which prompt/toolset)")
    field(:provider, :string, description: "agent provider: claude or codex")
    field(:model, :string, description: "sweep model")
    field(:effort, :string, description: "sweep effort")
    field(:agent, :string, description: "persona from .claude/agents/")
    field(:workspace, :string, description: "notebook home template")
    field(:working_dir, :string, description: "checkout path template")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out ambient persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "daily budget rail")
    field(:daily_budget_tokens, :integer, description: "daily token rail")
    field(:timeout_ms, :integer, description: "per-turn timeout")
    field(:max_turns, :integer, description: "agentic turns per run")
    field(:tags, {:list, :string}, description: "tags every wearer inherits")
    field(:sensors, {:list, :string}, description: "sensors derived per wearer")
    field(:system_prompt_file, :string, description: "standing-orders file path")
    field(:extra_allowed_tools, {:list, :string}, description: "GRANT: extra tools")

    field(:approve_bypass_permissions, :boolean,
      description: "GRANT: bypass_permissions on approval"
    )

    field(:approve_worktree, :string, description: "approved-arg worktree template")
    field(:approve_model, :string, description: "approved-arg model")
    field(:approve_effort, :string, description: "approved-arg effort")
  end

  @impl true
  def execute(params, frame) do
    envelope = ProfileTools.to_envelope(params)

    with :ok <- RosterTools.check_roster_writer(frame),
         {:ok, path} <- WriteBack.add_profile(params.name, envelope) do
      grants = WriteBack.dangerous_grants(envelope)

      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "define_profile #{params.name}: appended to #{path}, roster reloaded"
      })

      reply(frame, %{name: params.name, path: path, grants: grants, live: true})
    else
      {:error, reason} -> fail(frame, "define_profile refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown role/effort value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.ProfileTools.UpdateProfile do
  @moduledoc """
  Edit a profile on the roster file and reload (#236): every routine wearing
  it inherits the change at its next run. Only the operator and the
  caretaker's approved continuations may call this; propose it via
  request_permission with the preview_profile_edit render. `drop` removes an
  envelope key. Never auto.
  """
  use Anubis.Server.Component, type: :tool
  use Custode.MCP.NumericSchema

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.{ProfileTools, RosterTools}

  schema do
    field(:name, :string, required: true, description: "profile name to edit")
    field(:cron, :string, description: "new default cron")
    field(:prompt, :string, description: "new default sweep prompt")
    field(:role, :string, description: "new role")
    field(:provider, :string, description: "new agent provider: claude or codex")
    field(:model, :string, description: "new model")
    field(:effort, :string, description: "new effort")
    field(:agent, :string, description: "new persona")
    field(:workspace, :string, description: "new notebook home template")
    field(:working_dir, :string, description: "new checkout path template")
    field(:mcp, :boolean, description: "grant the custode MCP tools")
    field(:hermetic, :boolean, description: "seal out ambient persona")
    field(:max_budget_usd, {:either, {:integer, :float}}, description: "new per-turn budget rail")
    field(:daily_budget_usd, {:either, {:integer, :float}}, description: "new daily budget rail")
    field(:daily_budget_tokens, :integer, description: "new daily token rail")
    field(:timeout_ms, :integer, description: "new per-turn timeout")
    field(:max_turns, :integer, description: "new max turns")
    field(:tags, {:list, :string}, description: "replacement tag list")
    field(:sensors, {:list, :string}, description: "replacement sensor list")
    field(:system_prompt_file, :string, description: "standing-orders file path")
    field(:extra_allowed_tools, {:list, :string}, description: "GRANT: replacement tool list")

    field(:approve_bypass_permissions, :boolean,
      description: "GRANT: bypass_permissions on approval"
    )

    field(:approve_worktree, :string, description: "approved-arg worktree template")
    field(:approve_model, :string, description: "approved-arg model")
    field(:approve_effort, :string, description: "approved-arg effort")
    field(:drop, {:list, :string}, description: "envelope keys to REMOVE")
  end

  @impl true
  def execute(params, frame) do
    changes = ProfileTools.to_changes(params)

    with :ok <- RosterTools.check_roster_writer(frame),
         {:ok, path} <- WriteBack.update_profile(params.name, changes) do
      changed = changes |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "update_profile #{params.name}: #{changed} -- #{path} rewritten, roster reloaded"
      })

      reply(frame, %{name: params.name, path: path, live: true})
    else
      {:error, reason} -> fail(frame, "update_profile refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> fail(frame, "unknown role/effort value in #{inspect(Map.keys(params))}")
  end
end

defmodule Custode.MCP.ProfileTools.RemoveProfile do
  @moduledoc """
  Remove a profile from the roster and reload (#236). Refused while any
  routine still wears it -- pulling the envelope out from under a live
  routine would strip its grants mid-flight; reassign those routines first.
  Caretaker-only; propose via request_permission naming the profile and why.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:name, :string, required: true, description: "profile name to remove")
  end

  @impl true
  def execute(params, frame) do
    with :ok <- RosterTools.check_roster_writer(frame),
         {:ok, path} <- WriteBack.remove_profile(params.name) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: Custode.MCP.caller(frame).id,
        summary: "remove_profile #{params.name}: spliced out of #{path}, roster reloaded"
      })

      reply(frame, %{name: params.name, path: path, live: true})
    else
      {:error, reason} -> fail(frame, "remove_profile refused: #{inspect(reason)}")
    end
  end
end
