defmodule Custode.SubjectAssignmentLaunch do
  @moduledoc "Host-owned enqueue seam for newly started Claude helpers; no new worker or provider API."
  alias Custode.MCP.Identity
  alias Custode.{Repo, SubjectAssignments, SubjectDocuments}
  alias ObanClaude.Agent.Job

  @doc "The closure captures host configuration identity before the helper begins accepting prompts."
  def enqueue(helper_id, config_revision, args, meta) do
    SubjectAssignments.cleanup()

    case SubjectAssignments.pending(helper_id) do
      nil -> Job.new(args, meta: meta) |> Oban.insert()
      assignment -> enqueue_assignment(assignment, config_revision, args, meta)
    end
  end

  defp enqueue_assignment(assignment, config_revision, args, meta) do
    if meta["config_revision"] == config_revision do
      launch_id = "sl-" <> Ecto.UUID.generate()
      path = config_path(launch_id)
      token = Identity.mint_assignment(assignment.helper_id, launch_id)

      outcome = prepare_launch(assignment, args, meta, path, token, launch_id)

      case outcome do
        {:ok, job} ->
          {:ok, job}

        _failed ->
          Identity.revoke_assignment(launch_id)
          File.rm(path)
          {:error, :subject_assignment_enqueue_refused}
      end
    else
      {:error, :subject_assignment_configuration_changed}
    end
  end

  defp prepare_launch(assignment, args, meta, path, token, launch_id) do
    with :ok <- SubjectAssignments.admission_current?(assignment),
         :ok <- write_private_config(path, token) do
      Repo.transaction(fn -> insert_launch!(assignment, args, meta, path, launch_id) end,
        mode: :immediate
      )
    end
  rescue
    _error -> {:error, :assignment_launch_invalid}
  end

  defp insert_launch!(assignment, args, meta, path, launch_id) do
    args = scoped_args(args, assignment, path)

    job =
      case Job.new(args, meta: meta) |> Oban.insert() do
        {:ok, job} -> job
        {:error, _changeset} -> Repo.rollback("assignment_enqueue_failed")
      end

    SubjectAssignments.bind!(assignment, args, meta, path, launch_id, job)
  end

  defp scoped_args(args, assignment, path) do
    instruction =
      "\nHost-admitted subject assignment #{assignment.assignment_id}. " <>
        "Use subject_context on root #{assignment.root_id} for the admitted reads " <>
        Jason.encode!(assignment.record["read_paths"]) <>
        ". Create only the new Markdown output " <>
        assignment.record["destination"] <> ". No existing-document apply is authorized."

    args
    |> Map.put("mcp_config", [path])
    |> Map.put("strict_mcp_config", true)
    |> Map.put("hermetic", true)
    |> Map.put("allowed_tools", ["mcp__subject__subject_context"])
    |> Map.put("append_system_prompt", (args["append_system_prompt"] || "") <> instruction)
  end

  @doc false
  def config_path(id), do: Path.join(config_directory(), id <> ".json")

  defp config_directory do
    Path.expand(
      Path.join(Application.get_env(:custode, :mcp_config_dir, "tmp"), "subject-launches")
    )
  end

  defp write_private_config(path, token) do
    directory = Path.dirname(path)

    payload =
      Jason.encode!(%{
        "mcpServers" => %{
          "subject" => %{
            "type" => "http",
            "url" => Custode.MCP.memory_url(),
            "headers" => %{"Authorization" => "Bearer " <> token}
          }
        }
      })

    with :ok <- File.mkdir_p(directory),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, device} <- File.open(path, [:write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(device, payload)
      after
        File.close(device)
      end
    else
      _unavailable -> {:error, :private_launch_config_unavailable}
    end
  end

  @doc false
  def remove_config(launch) do
    if Regex.match?(~r/^sl-[0-9a-f-]{36}$/, launch.launch_id) and
         launch.config_path == config_path(launch.launch_id),
       do: File.rm(launch.config_path)

    :ok
  end

  @doc false
  def config_revision(args),
    do: SubjectDocuments.digest({"custode.subject_helper_launch.v1", args})
end
