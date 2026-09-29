defmodule Custode.LiveConfigReloadTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.AgentHandoff
  alias Custode.Agents
  alias Custode.Config.{Loader, WriteBack}
  alias Custode.Operator.Actions
  alias Custode.{OperatorMessages, Repo, Routine}

  @profile_name "live_config_reload"
  @profile :live_config_reload

  setup do
    id = uid("live-config")
    path = Path.join(System.tmp_dir!(), uid("live-config-roster") <> ".toml")
    workspace = tmp_workspace!()
    previous_config = System.get_env("CUSTODE_CONFIG")
    previous_routines = Application.fetch_env!(:custode, :routines)
    previous_sensors = Application.fetch_env!(:custode, :sensors)
    previous_profiles = Application.fetch_env!(:custode, :profiles)

    System.put_env("CUSTODE_CONFIG", path)
    Application.put_env(:custode, :routines, [])
    Application.put_env(:custode, :sensors, [])
    Application.put_env(:custode, :profiles, %{})

    on_exit(fn ->
      Application.put_env(
        :custode,
        :routines,
        Enum.reject(Application.fetch_env!(:custode, :routines), &(&1.id == id))
      )

      stop_if_live(id, :claude)
      stop_if_live(id, :codex)
      _ = AgentHandoff.reconcile(id)
      :ok = Custode.AgentHandoffIntent.clear(id)

      Repo.query!("DELETE FROM operator_messages WHERE target_agent_id = ?", [id])

      Repo.query!(
        "DELETE FROM conversation_arc_events WHERE conversation_arc_id IN " <>
          "(SELECT id FROM conversation_arcs WHERE routine_id = ?)",
        [id]
      )

      Repo.query!("DELETE FROM conversation_arcs WHERE routine_id = ?", [id])

      Repo.query!("DELETE FROM oban_jobs WHERE json_extract(meta, '$.agent_id') = ?", [id])

      File.rm(path)
      Application.put_env(:custode, :routines, previous_routines)
      Application.put_env(:custode, :sensors, previous_sensors)
      Application.put_env(:custode, :profiles, previous_profiles)
      restore_system_env("CUSTODE_CONFIG", previous_config)
    end)

    %{id: id, path: path, workspace: workspace}
  end

  for provider <- [:claude, :codex], source <- [:routine, :profile] do
    test "#{provider} #{source} rewrite with the same effective config keeps the live process",
         context do
      provider = unquote(provider)
      source = unquote(source)
      context = install_roster!(context, provider, source)
      routine = Routine.get(context.id)
      revision = Routine.execution_revision(routine)

      assert {:ok, pid} =
               Agents.start_agent(context.id, provider, Routine.agent_config(routine))

      assert Process.alive?(pid)
      assert revision == rewrite_same_model!(context)
      assert :ready = AgentHandoff.status(context.id)

      assert {:ok, %{state: :idle, config_revision: ^revision}} =
               Agents.info(context.id, provider)

      assert {:ok, ^pid} =
               Agents.start_agent(
                 context.id,
                 provider,
                 Routine.get(context.id) |> Routine.agent_config()
               )

      assert Process.alive?(pid)
    end

    test "#{provider} idle agent applies a #{source} edit to its first real turn", context do
      provider = unquote(provider)
      source = unquote(source)
      context = install_roster!(context, provider, source)
      old_revision = start_current_agent!(context)

      assert {:ok, :idle} = Agents.status(context.id, provider)
      new_revision = edit_model!(context)
      assert new_revision != old_revision

      eventually(fn ->
        assert :ready = AgentHandoff.status(context.id)

        assert {:ok, %{state: :idle, config_revision: ^new_revision}} =
                 Agents.info(context.id, provider)
      end)

      prompt = "first turn after #{source} edit #{context.id}"

      assert {:ok, receipt, :created} =
               Actions.message_with_receipt(context.id, prompt,
                 idempotency_key: "idle-#{context.id}"
               )

      assert receipt.delivery == "delivered"

      [job] =
        eventually(fn ->
          assert [job] = turns(context)
          [job]
        end)

      assert_job_contract(job, context.new_model, new_revision, prompt)
    end

    test "#{provider} running agent drains before a #{source} edit and replays one durable input",
         context do
      provider = unquote(provider)
      source = unquote(source)
      context = install_roster!(context, provider, source)
      old_revision = start_current_agent!(context)
      first_prompt = "old turn before #{source} edit #{context.id}"

      assert {:ok, _receipt, :created} =
               Actions.message_with_receipt(context.id, first_prompt,
                 idempotency_key: "old-#{context.id}"
               )

      [old_job] =
        eventually(fn ->
          assert [job] = turns(context)
          [job]
        end)

      assert_job_contract(old_job, context.old_model, old_revision, first_prompt)
      assert {:ok, :running} = Agents.status(context.id, provider)

      new_revision = edit_model!(context)
      assert new_revision != old_revision
      assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(context.id)

      queued_prompt = "queued exactly once during #{source} handoff #{context.id}"

      assert {:ok, queued, :created} =
               Actions.message_with_receipt(context.id, queued_prompt,
                 idempotency_key: "queued-#{context.id}"
               )

      assert queued.status == "queued"
      assert queued.delivery == "queued"
      assert [^old_job] = turns(context)

      assert :ok = finish_turn(provider, old_job)

      [_completed_old_job, new_job] =
        eventually(fn ->
          assert [completed_old_job, new_job] = turns(context)
          assert completed_old_job.id == old_job.id
          assert completed_old_job.state == "completed"
          [completed_old_job, new_job]
        end)

      assert_job_contract(new_job, context.new_model, new_revision, queued_prompt)

      assert 1 ==
               Enum.count(turns(context), fn job ->
                 String.contains?(job.args["prompt"], queued_prompt)
               end)

      eventually(fn ->
        assert :ready = AgentHandoff.status(context.id)

        assert %{status: "executing", delivery: "delivered", provider: provider_name} =
                 OperatorMessages.get(queued.message_id)

        assert provider_name == Atom.to_string(provider)
      end)
    end
  end

  for provider <- [:claude, :codex] do
    test "#{provider} provider Tick rejects a stale revision and delivers the current one",
         context do
      provider = unquote(provider)
      context = install_roster!(context, provider, :routine)
      old_tick = context.id |> Routine.get() |> Routine.tick_args()
      old_revision = start_current_agent!(context)

      new_revision = edit_model!(context)
      assert new_revision != old_revision

      eventually(fn ->
        assert :ready = AgentHandoff.status(context.id)

        assert {:ok, %{state: :idle, config_revision: ^new_revision}} =
                 Agents.info(context.id, provider)
      end)

      assert {:cancel, {:stale_tick, id}} =
               tick_worker(provider).perform(%Oban.Job{args: old_tick})

      assert id == context.id
      assert turns(context) == []

      current_tick = context.id |> Routine.get() |> Routine.tick_args()
      assert :ok = tick_worker(provider).perform(%Oban.Job{args: current_tick})

      [job] =
        eventually(fn ->
          assert [job] = turns(context)
          [job]
        end)

      assert_job_contract(job, context.new_model, new_revision, "run the live config regression")
    end

    test "#{provider} prompt-only edit fences the old Tick without replacing the live agent",
         context do
      provider = unquote(provider)
      context = install_roster!(context, provider, :routine)
      old_routine = Routine.get(context.id)
      old_execution_revision = Routine.execution_revision(old_routine)
      old_delivery_revision = Routine.delivery_revision(old_routine)
      old_prompt = old_routine.prompt
      old_tick = Routine.tick_args(old_routine)
      old_tick_job = %Oban.Job{args: old_tick}

      assert old_tick["delivery_revision"] == old_delivery_revision
      assert String.contains?(old_tick["prompt"], old_prompt)

      assert {:ok, pid} =
               Agents.start_agent(context.id, provider, Routine.agent_config(old_routine))

      new_prompt = "prompt-only live config #{context.id}"

      assert {:ok, context.path} ==
               WriteBack.update_routine(context.id, %{prompt: new_prompt})

      current_routine = Routine.get(context.id)
      current_tick = Routine.tick_args(current_routine)
      new_delivery_revision = Routine.delivery_revision(current_routine)

      assert Routine.execution_revision(current_routine) == old_execution_revision
      assert new_delivery_revision != old_delivery_revision
      assert current_tick["delivery_revision"] == new_delivery_revision
      assert String.contains?(current_tick["prompt"], new_prompt)
      refute String.contains?(current_tick["prompt"], old_prompt)
      assert :ready = AgentHandoff.status(context.id)

      assert {:ok, %{state: :idle, config_revision: ^old_execution_revision}} =
               Agents.info(context.id, provider)

      assert {:ok, ^pid} =
               Agents.start_agent(
                 context.id,
                 provider,
                 Routine.agent_config(current_routine)
               )

      assert Process.alive?(pid)

      assert {:cancel, {:stale_tick, id}} = tick_worker(provider).perform(old_tick_job)
      assert id == context.id
      assert turns(context) == []

      assert :ok = tick_worker(provider).perform(%Oban.Job{args: current_tick})

      [job] =
        eventually(fn ->
          assert [job] = turns(context)
          [job]
        end)

      assert_job_contract(job, context.old_model, old_execution_revision, new_prompt)
      refute String.contains?(job.args["prompt"], old_prompt)
    end
  end

  defp install_roster!(context, provider, source) do
    {old_model, new_model} = models(provider)

    profile = %{
      cron: :manual,
      prompt: "run the live config regression",
      role: :assistant,
      provider: provider,
      model: old_model
    }

    routine = %{
      id: context.id,
      profile: @profile,
      provider: provider,
      workspace: context.workspace,
      working_dir: context.workspace
    }

    routine = if source == :routine, do: Map.put(routine, :model, old_model), else: routine

    File.write!(
      context.path,
      WriteBack.render_profile(@profile_name, profile) <> WriteBack.render_routine(routine)
    )

    assert {:ok, _, _, _, _} = Loader.load!()
    assert %{provider: ^provider, model: ^old_model} = Routine.get(context.id)

    Map.merge(context, %{
      provider: provider,
      source: source,
      old_model: old_model,
      new_model: new_model
    })
  end

  defp start_current_agent!(context) do
    routine = Routine.get(context.id)
    revision = Routine.execution_revision(routine)

    assert {:ok, _pid} =
             Agents.start_agent(context.id, context.provider, Routine.agent_config(routine))

    assert {:ok, %{state: :idle, config_revision: ^revision}} =
             Agents.info(context.id, context.provider)

    revision
  end

  defp edit_model!(%{source: :routine} = context) do
    assert {:ok, context.path} ==
             WriteBack.update_routine(context.id, %{model: context.new_model})

    changed_revision(context)
  end

  defp edit_model!(%{source: :profile} = context) do
    assert {:ok, context.path} ==
             WriteBack.update_profile(@profile_name, %{model: context.new_model})

    changed_revision(context)
  end

  defp rewrite_same_model!(%{source: :routine} = context) do
    assert {:ok, context.path} ==
             WriteBack.update_routine(context.id, %{model: context.old_model})

    Routine.get(context.id) |> Routine.execution_revision()
  end

  defp rewrite_same_model!(%{source: :profile} = context) do
    assert {:ok, context.path} ==
             WriteBack.update_profile(@profile_name, %{model: context.old_model})

    Routine.get(context.id) |> Routine.execution_revision()
  end

  defp changed_revision(context) do
    routine = Routine.get(context.id)
    assert routine.model == context.new_model
    Routine.execution_revision(routine)
  end

  defp assert_job_contract(job, model, revision, prompt) do
    assert job.args["model"] == model
    assert job.meta["config_revision"] == revision
    assert String.contains?(job.args["prompt"], prompt)
  end

  defp turns(context) do
    context.provider
    |> worker_name()
    |> jobs_for()
    |> Enum.filter(&(&1.meta["agent_id"] == context.id))
  end

  defp finish_turn(:claude, job) do
    result = ObanClaude.Testing.result(session_id: Ecto.UUID.generate())

    :ok =
      ObanClaude.Agent.Job.handle_result(
        result,
        %Oban.Job{meta: job.meta, attempt: 1, max_attempts: 1}
      )

    complete_job!(job)
  end

  defp finish_turn(:codex, job) do
    result = ObanCodex.Testing.result(session_id: Ecto.UUID.generate())

    :ok =
      ObanCodex.Agent.Job.handle_result(
        result,
        %Oban.Job{meta: job.meta, attempt: 1, max_attempts: 1}
      )

    complete_job!(job)
  end

  # The real Oban worker marks its row completed after perform/1 returns. These
  # integration tests drive handle_result/2 directly, so model that durable
  # transition before expecting the handoff fence to replay queued input.
  defp complete_job!(job) do
    Oban.Job
    |> Repo.get!(job.id)
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    :ok
  end

  defp stop_if_live(id, provider) do
    case Agents.status(id, provider) do
      {:ok, :offline} -> :ok
      {:ok, _state} -> Agents.stop_agent(id, provider)
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp models(:claude), do: {"haiku", "sonnet"}
  defp models(:codex), do: {"gpt-5.6-luna", "gpt-5.6-sol"}

  defp worker_name(:claude), do: "ObanClaude.Agent.Job"
  defp worker_name(:codex), do: "ObanCodex.Agent.Job"

  defp tick_worker(:claude), do: ObanClaude.Agent.Tick
  defp tick_worker(:codex), do: ObanCodex.Agent.Tick
end
