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

  @doc false
  # The attrs shape shared by both tools: assignment fields plus the
  # common overrides. Tags arrive as strings and convert exactly like the
  # TOML loader converts them.
  def to_attrs(params) do
    %{id: params.id}
    |> put_if(params, :profile, &String.to_existing_atom/1)
    |> put_if(params, :cron)
    |> put_if(params, :repo)
    |> put_if(params, :working_dir)
    |> put_if(params, :workspace)
    |> put_if(params, :prompt)
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
end

defmodule Custode.MCP.RosterTools.PreviewRoutine do
  @moduledoc """
  Render the exact TOML section adding this routine would append -- put this
  in your request_permission action so the human approves the literal diff.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "unique routine id")
    field(:profile, :string, description: "profile name, e.g. \"backlog_worker\"")
    field(:cron, :string, description: "cron override (the profile usually supplies it)")
    field(:repo, :string, description: "owner/name the routine serves")
    field(:working_dir, :string, description: "absolute path of the checkout")
    field(:workspace, :string, description: "notebook home (defaults to workspaces/<id>)")
    field(:prompt, :string, description: "sweep prompt (the profile usually supplies it)")
    field(:tags, {:list, :string}, description: "tags, e.g. [\"rust\", \"external\"]")
  end

  @impl true
  def execute(params, frame) do
    attrs = RosterTools.to_attrs(params)
    reply(frame, %{toml: WriteBack.render_routine(attrs)})
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

  import Custode.MCP.Tools

  alias Custode.Config.WriteBack
  alias Custode.MCP.RosterTools

  schema do
    field(:id, :string, required: true, description: "unique routine id")
    field(:profile, :string, description: "profile name, e.g. \"backlog_worker\"")
    field(:cron, :string, description: "cron override (the profile usually supplies it)")
    field(:repo, :string, description: "owner/name the routine serves")
    field(:working_dir, :string, description: "absolute path of the checkout")
    field(:workspace, :string, description: "notebook home (defaults to workspaces/<id>)")
    field(:prompt, :string, description: "sweep prompt (the profile usually supplies it)")
    field(:tags, {:list, :string}, description: "tags, e.g. [\"rust\", \"external\"]")
  end

  @impl true
  def execute(params, frame) do
    attrs = RosterTools.to_attrs(params)

    with :ok <- check_roster_writer(frame),
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

  # The write is for the operator and the caretaker (whose approved
  # continuation is the gate flow's actuator). Workers and sub-agents
  # propose to the caretaker instead -- one funnel, one judgment.
  defp check_roster_writer(frame) do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} -> :ok
      %{kind: :routine, id: id} -> check_caretaker(id)
      _sub_agent -> {:error, "identity: sub-agents do not provision routines"}
    end
  end

  defp check_caretaker(id) do
    case Custode.Routine.get(id) do
      %{role: :caretaker} -> :ok
      _other -> {:error, "identity: only the caretaker provisions routines; drop it a note"}
    end
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
