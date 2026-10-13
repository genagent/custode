defmodule AdapterProof.Repo do
  use Ecto.Repo, otp_app: :adapter_proof, adapter: Ecto.Adapters.SQLite3
end

defmodule AdapterProof.Project do
  use Ecto.Schema

  schema "projects" do
    field(:paused, :boolean, default: false)
    field(:revision, :integer, default: 0)
    field(:generation, :integer, default: 0)
    field(:active_turn_id, :integer)
  end
end

defmodule AdapterProof.Turn do
  use Ecto.Schema

  schema "project_turns" do
    field(:project_id, :integer)
    field(:state, :string, default: "queued")
    field(:spec, :map)
    field(:report, :map)
  end
end

defmodule AdapterProof.Attempt do
  use Ecto.Schema

  schema "project_turn_attempts" do
    field(:turn_id, :integer)
    field(:generation, :integer)
    field(:phase, :string, default: "admitted")
    field(:spec, :map)
    field(:spec_hash, :string)
    field(:native, :map)
    field(:native_inventory, :map, default: %{})
    field(:terminal, :map)
    field(:quiescence, :map)
    field(:stop_requested, :boolean, default: false)
  end
end

defmodule AdapterProof.Journal do
  @moduledoc "Proof-only durable admission and settlement boundary. No fleet integration."
  import Ecto.Query
  alias AdapterProof.{Attempt, Project, Repo, Turn}

  def project(id), do: Repo.get!(Project, id)
  def turn(id), do: Repo.get!(Turn, id)
  def attempt(id), do: Repo.get!(Attempt, id)
  def attempt_for(turn), do: Repo.get_by(Attempt, turn_id: turn)
  def create_project, do: Repo.insert!(%Project{})
  def enqueue(project, spec), do: Repo.insert!(%Turn{project_id: project, spec: spec})

  def snapshot do
    %{
      projects:
        Repo.all(from(p in Project, select: map(p, [:id, :paused, :generation, :active_turn_id]))),
      turns: Repo.all(from(t in Turn, select: map(t, [:id, :state, :report]))),
      attempts:
        Repo.all(
          from(a in Attempt, select: map(a, [:id, :phase, :native, :terminal, :quiescence]))
        )
    }
  end

  def pause(id, value) when is_boolean(value) do
    Repo.update_all(from(p in Project, where: p.id == ^id),
      set: [paused: value],
      inc: [revision: 1]
    )

    project(id)
  end

  def admit(turn_id) do
    Repo.transaction(fn ->
      turn = turn(turn_id)

      case attempt_for(turn.id) do
        nil -> reserve(turn)
        attempt -> {:existing, attempt}
      end
    end)
  end

  defp reserve(turn) do
    query =
      from(p in Project,
        where: p.id == ^turn.project_id and not p.paused and is_nil(p.active_turn_id)
      )

    case Repo.update_all(query, set: [active_turn_id: turn.id], inc: [generation: 1]) do
      {1, _} ->
        project = project(turn.project_id)

        attempt =
          Repo.insert!(%Attempt{
            turn_id: turn.id,
            generation: project.generation,
            spec: turn.spec,
            spec_hash: digest(turn.spec)
          })

        persist(turn, state: "running")
        {:new, attempt}

      {0, _} ->
        :held
    end
  end

  def prompt(attempt) do
    Jason.encode!(%{attempt: attempt.id, generation: attempt.generation, spec: attempt.spec})
  end

  # Consumption happens before the backend can launch. Pause does not revoke an
  # already admitted permit; duplicate or unadmitted prompts cannot consume it.
  def consume(prompt, project_id) do
    {:ok, consumed} = Repo.transaction(fn -> consume_bound(prompt, project_id) end)
    consumed
  end

  defp consume_bound(prompt, project_id) do
    with {:ok, %{"attempt" => id, "generation" => generation, "spec" => spec}} <-
           Jason.decode(prompt),
         %Attempt{} = attempt <- Repo.get(Attempt, id),
         true <- attempt.generation == generation and attempt.spec_hash == digest(spec) do
      turn = turn(attempt.turn_id)
      project = project(turn.project_id)

      if project.id == project_id and project.active_turn_id == turn.id and
           project.generation == generation do
        {count, _} =
          Repo.update_all(
            from(a in Attempt,
              where: a.id == ^id and a.phase == "admitted"
            ),
            set: [phase: "dispatching"]
          )

        count == 1
      else
        false
      end
    else
      _ -> false
    end
  end

  def checkpoint(id, native_id), do: persist(attempt(id), native: %{"session_id" => native_id})

  def observe_native(id, event) do
    Repo.transaction(fn ->
      attempt = attempt(id)
      if attempt.spec["token"] != event["token"], do: Repo.rollback(:unbound_native)
      inventory = Map.put(attempt.native_inventory, event["role"], event)
      persist(attempt, native_inventory: inventory)
    end)
  end

  def terminal(id, value) do
    Repo.transaction(fn ->
      Repo.update_all(from(a in Attempt, where: a.id == ^id and is_nil(a.terminal)),
        set: [terminal: value]
      )

      settle(id)
    end)
  end

  def quiescent(id, evidence) do
    Repo.transaction(fn ->
      attempt = attempt(id)

      unless evidence["attempt"] == id and evidence["token"] == attempt.spec["token"] and
               evidence["scope"] == "closed_fixture_inventory" do
        Repo.rollback(:unbound_evidence)
      end

      persist(attempt, quiescence: evidence)
      settle(id)
    end)
  end

  def request_stop(id), do: persist(attempt(id), stop_requested: true)

  def uncertain(id) do
    Repo.transaction(fn ->
      attempt = attempt(id)
      turn = turn(attempt.turn_id)
      # Observational reconciliation is not revocation. The original admitted
      # caller may still consume its one-use permit, including after pause.
      # Redelivery itself never submits that permit to GenAgent again.
      if is_nil(turn.report), do: persist(turn, state: "uncertain")
      turn(turn.id)
    end)
  end

  defp settle(id) do
    attempt = attempt(id)
    turn = turn(attempt.turn_id)

    if attempt.terminal && attempt.quiescence && is_nil(turn.report) do
      report = Map.put(attempt.terminal, "attempt_id", id)
      persist(turn, state: "completed", report: report)

      Repo.update_all(
        from(p in Project,
          where:
            p.id == ^turn.project_id and p.active_turn_id == ^turn.id and
              p.generation == ^attempt.generation
        ),
        set: [active_turn_id: nil]
      )

      persist(attempt, phase: "settled")
    end

    turn(turn.id)
  end

  defp persist(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()
  defp digest(spec), do: :crypto.hash(:sha256, :erlang.term_to_binary(spec)) |> Base.encode16()
end
