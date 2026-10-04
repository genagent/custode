defmodule CustodeGenAgentProof.CompatibilityTest do
  use ExUnit.Case, async: false
  alias GenAgent.Event
  alias GenAgentEnsemble.Agents.Simple
  alias GenAgentEnsemble.Strategies.Pool

  defmodule Backend do
    @behaviour GenAgent.Backend
    def start_session(opts),
      do:
        {:ok,
         %{
           observer: Keyword.fetch!(opts, :observer),
           options: opts,
           id: Keyword.get(opts, :resume),
           script: Keyword.fetch!(opts, :script)
         }}

    def prompt(session, prompt), do: prompt(session, prompt, %{checkpoint: fn _ -> :ok end})

    def prompt(session, prompt, context) do
      send(session.observer, {:dispatch, prompt, session.id, session.options, self(), context})
      {:ok, session.script.(prompt, context), session}
    end

    def checkpoint_session(session, id) do
      if path = session.options[:checkpoint_path], do: File.write!(path, id)
      send(session.observer, {:checkpoint, id})
      %{session | id: id}
    end

    def resume_session(id, opts) do
      send(Keyword.fetch!(opts, :observer), {:unexpected_core_restore, id})
      start_session(Keyword.put(opts, :resume, id))
    end

    def terminate_session(_session), do: :ok
  end

  defp name, do: "custode-proof-#{System.unique_integer([:positive])}"
  defp result(text), do: Event.new(:result, %{text: text})

  defp start_agent(script, opts \\ []) do
    name = name()

    {:ok, _} =
      GenAgent.start_agent(
        Simple,
        [name: name, backend: Backend, observer: self(), script: script] ++ opts
      )

    on_exit(fn -> if GenAgent.whereis(name), do: GenAgent.stop(name) end)
    name
  end

  test "early checkpoint survives provider failure but core restart does not restore it" do
    script = fn
      "fail", context ->
        Stream.map([:checkpoint], fn _ ->
          :ok = context.checkpoint.("recorded-native-id")
          Event.new(:error, %{reason: :fixture_provider_failure})
        end)

      "next", _ ->
        [result("ok")]
    end

    name = start_agent(script)
    assert {:error, :fixture_provider_failure} = GenAgent.ask(name, "fail")
    assert_receive {:checkpoint, "recorded-native-id"}
    assert {:ok, _} = GenAgent.ask(name, "next")
    assert_receive {:dispatch, "next", "recorded-native-id", _, _, _}
    :ok = GenAgent.stop(name)

    {:ok, _} =
      GenAgent.start_agent(Simple, name: name, backend: Backend, observer: self(), script: script)

    assert {:ok, _} = GenAgent.ask(name, "next")
    assert_receive {:dispatch, "next", nil, _, _, _}
    refute_receive {:unexpected_core_restore, _}
    refute Map.has_key?(GenAgent.runtime_snapshot(name), :backend_session)
  end

  test "host persists a checkpoint before completion and restores it at a fresh boundary" do
    path = Path.join(System.tmp_dir!(), name() <> ".checkpoint")
    on_exit(fn -> File.rm(path) end)

    script = fn _, context ->
      Stream.map([:checkpoint], fn _ ->
        :ok = context.checkpoint.("host-recorded-id")
        result("restored")
      end)
    end

    original = start_agent(script, checkpoint_path: path, allowed_tools: ["Read"])
    assert {:ok, _} = GenAgent.ask(original, "record")
    assert File.read!(path) == "host-recorded-id"
    :ok = GenAgent.stop(original)

    restored =
      start_agent(fn _, _ -> [result("ok")] end,
        resume: File.read!(path),
        allowed_tools: ["Read"]
      )

    assert {:ok, _} = GenAgent.ask(restored, "review")
    assert_receive {:dispatch, "review", "host-recorded-id", options, _, _}
    assert options[:allowed_tools] == ["Read"]
  end

  test "per-turn option arguments do not change frozen backend tool policy" do
    name =
      start_agent(fn _, _ -> [result("ok")] end, allowed_tools: ["Read"], model: "captured-model")

    assert {:ok, ref} =
             GenAgent.tell_with_completion(name, "approved continuation", self(), 5_000,
               allowed_tools: ["Write"],
               model: "other-model"
             )

    assert_receive {:dispatch, "approved continuation", _, options, _, context}
    assert options[:allowed_tools] == ["Read"]
    assert options[:model] == "captured-model"
    assert Map.keys(context) == [:checkpoint]
    assert_receive {:gen_agent, :completion, ^name, ^ref, {:ok, _}}
  end

  test "cancelled checkpoint closure cannot update a successor" do
    owner = self()

    script = fn
      "hold", _ ->
        Stream.map([:wait], fn _ ->
          send(owner, :held)
          Process.sleep(30_000)
          result("late")
        end)

      "successor", context ->
        Stream.map([:checkpoint], fn _ ->
          :ok = context.checkpoint.("successor-id")
          result("successor")
        end)
    end

    name = start_agent(script)
    assert {:ok, ref} = GenAgent.tell(name, "hold")
    assert_receive {:dispatch, "hold", _, _, _, %{checkpoint: checkpoint}}
    assert_receive :held
    assert {:ok, :accepted} = GenAgent.interrupt_request(name, ref)
    assert {:error, _} = checkpoint.("stale-id")
    assert {:ok, _} = GenAgent.ask(name, "successor")
    assert_receive {:checkpoint, "successor-id"}
    refute_receive {:checkpoint, "stale-id"}
  end

  defp start_pool(script, count \\ 2) do
    name = name()

    {:ok, pid} =
      GenAgentEnsemble.start_link(
        name: name,
        strategy: Pool,
        opts: [
          worker_count: count,
          worker_template:
            {"review", Simple, [backend: Backend, observer: self(), script: script]}
        ]
      )

    Process.unlink(pid)

    on_exit(fn ->
      try do
        GenAgentEnsemble.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end

  test "parallel reviews are independent and partial failure remains distinct evidence" do
    owner = self()

    script = fn prompt, _ ->
      Stream.map([:wait], fn _ ->
        send(owner, {:review_ready, prompt, self()})

        receive do
          :release ->
            if prompt == "failed",
              do: Event.new(:error, %{reason: :review_failed}),
              else: result(prompt)
        end
      end)
    end

    name = start_pool(script)
    assert {:ok, good} = GenAgentEnsemble.tell_with_completion(name, "successful", self())
    assert {:ok, bad} = GenAgentEnsemble.tell_with_completion(name, "failed", self())
    assert_receive {:review_ready, "successful", good_pid}
    assert_receive {:review_ready, "failed", bad_pid}
    refute good_pid == bad_pid
    {:ok, status} = GenAgentEnsemble.status(name)
    assert status.busy == 2
    [{ensemble, _}] = Registry.lookup(GenAgentEnsemble.Registry, name)

    refs =
      for {ref, {agent, token}} <- :sys.get_state(ensemble).in_flight, do: {ref, agent, token}

    assert length(refs) == 2
    send(good_pid, :release)
    send(bad_pid, :release)
    assert {:ok, %{text: "successful"}} = GenAgentEnsemble.await(name, good)
    assert {:error, :review_failed} = GenAgentEnsemble.await(name, bad)
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^good, {:ok, _}}
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^bad, {:error, :review_failed}}

    for {ref, agent, _token} <- refs do
      send(ensemble, {:gen_agent, :completion, "#{name}/#{agent}", ref, {:error, :duplicate}})
    end

    :sys.get_state(ensemble)
    assert {:ok, :completed, %{text: "successful"}} = GenAgentEnsemble.poll(name, good)
    assert {:error, :review_failed} = GenAgentEnsemble.poll(name, bad)
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^good, _}
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^bad, _}
  end

  test "cancel closes one token and fences a fabricated late completion" do
    owner = self()

    script = fn prompt, _ ->
      Stream.map([:wait], fn _ ->
        send(owner, {:review_ready, prompt, self()})
        Process.sleep(30_000)
        result("too late")
      end)
    end

    name = start_pool(script, 1)
    {:ok, token} = GenAgentEnsemble.tell_with_completion(name, "cancel", self())
    assert_receive {:review_ready, "cancel", task}
    task_monitor = Process.monitor(task)
    [{ensemble, _}] = Registry.lookup(GenAgentEnsemble.Registry, name)
    refs = for {ref, {agent, ^token}} <- :sys.get_state(ensemble).in_flight, do: {ref, agent}
    assert length(refs) == 1
    assert {:ok, how} = GenAgentEnsemble.cancel(name, token)
    assert how in [:cancelled, :cancelled_unconfirmed]
    assert {:error, :cancelled} = GenAgentEnsemble.await(name, token)
    assert_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:error, :cancelled}}
    assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}, 5_000
    # Replay the actual child-completion envelope with the original ref.
    # This proves coordinator fencing, not OS subprocess settlement.
    for {ref, agent} <- refs do
      send(
        ensemble,
        {:gen_agent, :completion, "#{name}/#{agent}", ref,
         {:ok, %GenAgent.Response{text: "fabricated"}}}
      )

      send(ensemble, {:gen_agent, :completion, "#{name}/#{agent}", ref, {:error, :late_failure}})
    end

    :sys.get_state(ensemble)
    assert {:error, :cancelled} = GenAgentEnsemble.poll(name, token)
    refute_receive {:gen_agent_ensemble, :completion, ^name, ^token, {:ok, _}}
  end
end
