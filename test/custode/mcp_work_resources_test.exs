defmodule Custode.MCPWorkResourcesTest do
  use ExUnit.Case, async: false

  alias Custode.TestHelpers

  alias Custode.MCP.CallContext, as: Frame

  alias Custode.{
    Artifact,
    Artifacts,
    Asks,
    Attempts,
    ContextBundles,
    Gates,
    Mission,
    Repo,
    SpendLedger,
    WorkEvent,
    WorkItem
  }

  alias Custode.MCP.{MemoryServer, Server}

  @inserted_at ~U[2026-07-29 12:00:00.000000Z]

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-mcp-resources-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "stateless discovery retains the complete operator resource catalog" do
    assert Map.has_key?(Server.server_capabilities(), "resources")
    assert Map.has_key?(Server.server_capabilities(), "tools")
    refute Map.has_key?(MemoryServer.server_capabilities(), "resources")
    operator = initialized_frame(:operator)

    for _request <- 1..2 do
      assert {:reply, %{"resources" => resources}, ^operator} =
               TestHelpers.mcp_dispatch("resources/list", %{}, operator)

      assert Enum.map(resources, & &1["uri"]) |> Enum.sort() ==
               Enum.sort(
                 ~w(custode://attention custode://work-events custode://work-items custode://missions)
               )

      assert Enum.all?(resources, &(&1["mimeType"] == "application/json"))

      assert {:reply, %{"resourceTemplates" => templates}, ^operator} =
               TestHelpers.mcp_dispatch("resources/templates/list", %{}, operator)

      assert length(templates) == 13

      assert "custode://work-items/{work_item_id}/attempt" in Enum.map(
               templates,
               & &1["uriTemplate"]
             )

      assert "custode://missions/{mission_id}/work-items/pages/{cursor}" in Enum.map(
               templates,
               & &1["uriTemplate"]
             )
    end

    routine = initialized_frame(:routine)
    assert {:error, %{"code" => -32_002}, ^routine} = read("custode://missions", routine)
    assert "list_attention" in Enum.map(Server.tools(), & &1.name())
  end

  test "empty resources return stable read-only contracts and missing details are not found" do
    frame = initialized_frame(:operator)

    assert %{
             "contract" => "custode.mission.list.v1",
             "items" => [],
             "page" => %{"has_more" => false, "next_uri" => nil}
           } = read_json!("custode://missions", frame)

    assert %{
             "contract" => "custode.work_item.list.v1",
             "items" => [],
             "page" => %{"has_more" => false}
           } = read_json!("custode://work-items", frame)

    assert %{
             "contract" => "custode.work_event.list.v1",
             "items" => []
           } = read_json!("custode://work-events", frame)

    assert %{
             "contract" => "custode.attention.list.v1",
             "items" => [],
             "projection" => %{
               "derived" => true,
               "independently_mutable" => false
             }
           } = read_json!("custode://attention", frame)

    assert {:error, %{"code" => -32_002}, ^frame} =
             read("custode://missions/missing", frame)

    assert {:error, %{"code" => -32_002}, ^frame} =
             read("custode://work-items/missing/events", frame)

    assert {:error, %{"code" => -32_002}, ^frame} =
             read("custode://work-items/missing/artifacts", frame)

    assert {:error, %{"code" => -32_602}, ^frame} =
             read("custode://work-events/pages/not-a-cursor", frame)
  end

  test "resources expose active, waiting, blocked, and completed work with provenance", %{
    artifact_dir: artifact_dir
  } do
    frame = initialized_frame(:operator)
    fixture = insert_lifecycle_fixture!(artifact_dir)

    work = read_json!("custode://work-items", frame)

    assert Enum.map(work["items"], &{&1["work_item_id"], &1["state"], &1["phase"]}) == [
             {"work-active", "active", "implementing"},
             {"work-blocked", "blocked", "repair_ready"},
             {"work-completed", "completed", "landed"},
             {"work-waiting", "waiting", "awaiting_review"}
           ]

    active = read_json!("custode://work-items/work-active", frame)
    assert active["state"] == "active"
    assert active["phase"] == "implementing"
    assert active["state"] != active["phase"]
    assert active["relationships"]["attempt_ids"] == [fixture.attempt.attempt_id]
    assert active["relationships"]["artifact_ids"] != []
    assert active["links"]["mission"] == "custode://missions/mission-resources"
    assert active["links"]["events"] == "custode://work-items/work-active/events"

    current = read_json!("custode://work-items/work-active/attempt", frame)
    assert current["contract"] == "custode.work_item.current_attempt.v1"
    assert current["attempt"]["attempt_id"] == fixture.attempt.attempt_id
    assert current["attempt"]["active"]
    assert current["attempt"]["provider"] == "codex"

    artifacts = read_json!("custode://work-items/work-active/artifacts", frame)
    assert artifacts["contract"] == "custode.artifact.list.v1"
    assert Enum.all?(artifacts["items"], &(&1["contract"] == "custode.artifact.v1"))

    assert fixture.bundle.artifact.artifact_id in Enum.map(
             artifacts["items"],
             & &1["artifact_id"]
           )

    assert fixture.artifact.artifact_id in Enum.map(artifacts["items"], & &1["artifact_id"])

    events = read_json!("custode://work-events", frame)

    assert Enum.map(events["items"], & &1["event_id"]) ==
             ~w(event-active event-blocked event-completed event-waiting)

    assert Enum.all?(events["items"], &(&1["contract"] == "custode.work_event.v1"))

    blocked_events = read_json!("custode://work-items/work-blocked/events", frame)
    assert [blocked_event] = blocked_events["items"]
    assert blocked_event["after"]["state"] == "blocked"
    assert blocked_event["after"]["phase"] == "repair_ready"
    assert blocked_event["correlation_id"] == "corr-blocked"
    assert blocked_event["causation_id"] == "cause-blocked"
    assert blocked_event["mission_id"] == fixture.mission.mission_id

    attention = read_json!("custode://attention", frame)
    assert attention["projection"]["derived"]
    assert [blocked_attention] = attention["items"]
    assert blocked_attention["subject"]["id"] == "work-blocked"
    assert blocked_attention["source"]["kind"] == "work_item"
    assert blocked_attention["source"]["resource_uri"] == "custode://work-items/work-blocked"
    assert blocked_attention["source"]["relationship"] == "self"

    assert blocked_attention["links"]["authoritative_source"] ==
             "custode://work-items/work-blocked"

    mission = read_json!("custode://missions/mission-resources", frame)

    assert Enum.sort(mission["relationships"]["work_item_ids"]) ==
             ~w(work-active work-blocked work-completed work-waiting)

    assert mission["links"]["work_items"] ==
             "custode://missions/mission-resources/work-items"

    scoped_work =
      read_json!("custode://missions/mission-resources/work-items", frame)

    assert Enum.map(scoped_work["items"], & &1["work_item_id"]) ==
             ~w(work-active work-blocked work-completed work-waiting)
  end

  test "resource page links preserve deterministic opaque cursor scope" do
    frame = initialized_frame(:operator)

    for index <- 0..25 do
      id = "mission-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"
      insert_mission!(id)
    end

    first = read_json!("custode://missions", frame)
    assert length(first["items"]) == 25
    assert first["page"]["has_more"]
    assert is_binary(first["page"]["next_cursor"])
    assert first["page"]["next_uri"] == first["links"]["next"]

    second = read_json!(first["page"]["next_uri"], frame)
    assert Enum.map(second["items"], & &1["mission_id"]) == ["mission-25"]
    refute second["page"]["has_more"]
    assert second["page"]["next_uri"] == nil

    mission = Repo.get_by!(Mission, mission_id: "mission-00")

    work_items =
      for index <- 0..25 do
        padded = index |> Integer.to_string() |> String.pad_leading(2, "0")
        work_item = insert_work_item!(mission, "work-#{padded}", "blocked", "repair_ready")

        insert_event!(mission, work_item, "event-#{padded}", "work_item.transitioned",
          correlation_id: "corr-#{padded}",
          causation_id: "cause-#{padded}"
        )

        work_item
      end

    scoped = read_json!("custode://missions/mission-00/work-items", frame)
    assert length(scoped["items"]) == 25

    assert String.starts_with?(
             scoped["page"]["next_uri"],
             "custode://missions/mission-00/work-items/pages/"
           )

    next = read_json!(scoped["page"]["next_uri"], frame)
    assert Enum.map(next["items"], & &1["work_item_id"]) == ["work-25"]

    events = read_json!("custode://work-events", frame)
    assert length(events["items"]) == 25
    assert Enum.map(events["items"], & &1["event_id"]) == Enum.map(0..24, &padded_id("event", &1))

    event_tail = read_json!(events["page"]["next_uri"], frame)
    assert Enum.map(event_tail["items"], & &1["event_id"]) == ["event-25"]

    attention = read_json!("custode://attention", frame)
    assert length(attention["items"]) == 25
    assert attention["projection"]["derived"]

    attention_tail = read_json!(attention["page"]["next_uri"], frame)
    assert Enum.map(attention_tail["items"], & &1["subject"]["id"]) == ["work-25"]

    first_work_item = List.first(work_items)

    for index <- 0..25 do
      insert_artifact!(mission, first_work_item, padded_id("artifact", index))
    end

    artifacts = read_json!("custode://work-items/work-00/artifacts", frame)
    assert length(artifacts["items"]) == 25

    assert Enum.map(artifacts["items"], & &1["artifact_id"]) ==
             Enum.map(0..24, &padded_id("artifact", &1))

    artifact_tail = read_json!(artifacts["page"]["next_uri"], frame)
    assert Enum.map(artifact_tail["items"], & &1["artifact_id"]) == ["artifact-25"]

    cursor = scoped["page"]["next_cursor"]

    assert {:error, %{"code" => -32_602}, ^frame} =
             read("custode://work-items/pages/#{cursor}", frame)
  end

  defp initialized_frame(kind) do
    %Frame{
      assigns: %{
        custode_identity: %{
          kind: kind,
          id: if(kind == :operator, do: "operator", else: "routine")
        }
      }
    }
  end

  defp read(uri, frame),
    do: TestHelpers.mcp_dispatch("resources/read", %{"uri" => uri}, frame)

  defp read_json!(uri, frame) do
    assert {:reply,
            %{
              "contents" => [
                %{
                  "uri" => ^uri,
                  "mimeType" => "application/json",
                  "text" => encoded
                }
              ]
            }, ^frame} = read(uri, frame)

    Jason.decode!(encoded)
  end

  defp insert_lifecycle_fixture!(artifact_dir) do
    mission = insert_mission!("mission-resources")
    active = insert_work_item!(mission, "work-active", "ready", "eligible")
    blocked = insert_work_item!(mission, "work-blocked", "blocked", "repair_ready")
    completed = insert_work_item!(mission, "work-completed", "completed", "landed")
    waiting = insert_work_item!(mission, "work-waiting", "waiting", "awaiting_review")

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(active.work_item_id, context_body(active),
               artifact_dir: artifact_dir
             )

    assert {:ok, {:created, attempt}} =
             Attempts.create(%{
               attempt_id: "attempt-resource",
               work_item_id: active.work_item_id,
               context_bundle_id: bundle.context_bundle_id,
               executor_kind: "model",
               provider: "codex",
               profile: "gpt-5.6",
               recipe_version: "1",
               expected_work_item_version: active.version
             })

    active =
      active
      |> Ecto.Changeset.change(
        state: "active",
        phase: "implementing",
        active_attempt_id: attempt.attempt_id
      )
      |> Repo.update!()

    assert {:ok, artifact} =
             Artifacts.create(%{
               artifact_id: "artifact-resource",
               work_item_id: active.work_item_id,
               producer_attempt_id: attempt.attempt_id,
               kind: "diff",
               digest: String.duplicate("a", 64),
               media_type: "text/plain",
               location: Path.join(artifact_dir, "diff.txt"),
               size_bytes: 12,
               provenance: %{executor: "codex"},
               retention: %{policy: "mission"}
             })

    insert_event!(mission, active, "event-active", "work_item.transitioned",
      correlation_id: "corr-active",
      causation_id: "cause-active"
    )

    insert_event!(mission, blocked, "event-blocked", "work_item.transitioned",
      correlation_id: "corr-blocked",
      causation_id: "cause-blocked"
    )

    insert_event!(mission, completed, "event-completed", "work_item.transitioned",
      correlation_id: "corr-completed",
      causation_id: "cause-completed"
    )

    insert_event!(mission, waiting, "event-waiting", "work_item.transitioned",
      correlation_id: "corr-waiting",
      causation_id: "cause-waiting"
    )

    %{
      mission: mission,
      active: active,
      blocked: blocked,
      completed: completed,
      waiting: waiting,
      bundle: bundle,
      attempt: attempt,
      artifact: artifact
    }
  end

  defp insert_mission!(mission_id) do
    %{
      mission_id: mission_id,
      key: "test:#{mission_id}",
      purpose: "Test #{mission_id}",
      lifecycle: "persistent",
      status: "active"
    }
    |> Mission.create_changeset()
    |> Repo.insert!()
    |> Ecto.Changeset.change(inserted_at: @inserted_at, updated_at: @inserted_at)
    |> Repo.update!()
  end

  defp insert_work_item!(mission, work_item_id, state, phase) do
    attrs = %{
      work_item_id: work_item_id,
      mission_id: mission.id,
      kind: "github_issue_to_merge",
      workflow_version: 1,
      objective: "Test #{work_item_id}",
      acceptance_criteria: %{"tests" => "pass"},
      state: state,
      phase: phase,
      priority: 0,
      source: "mcp-resource-test",
      external_key: "mcp-resource-test:#{work_item_id}",
      version: 1,
      waiting_condition: if(state == "waiting", do: %{"kind" => "review"}, else: nil),
      blocked_reason:
        if(state == "blocked",
          do: %{"code" => "repair_policy_exhausted", "detail" => "no repairs remain"},
          else: nil
        ),
      outcome: if(state == "completed", do: %{"kind" => "merged"}, else: nil),
      completed_at: if(state == "completed", do: @inserted_at, else: nil)
    }

    attrs
    |> WorkItem.create_changeset()
    |> Repo.insert!()
    |> Ecto.Changeset.change(inserted_at: @inserted_at, updated_at: @inserted_at)
    |> Repo.update!()
    |> Repo.preload(:mission)
  end

  defp insert_event!(mission, work_item, event_id, kind, options) do
    %{
      event_id: event_id,
      work_item_id: work_item.id,
      mission_id: mission.id,
      kind: kind,
      actor: %{"kind" => "operator", "id" => "operator"},
      operation: "work_items.transition",
      before_state: "ready",
      before_phase: "eligible",
      after_state: work_item.state,
      after_phase: work_item.phase,
      before_version: 0,
      work_item_version: work_item.version,
      evidence: %{"source" => "resource-test"},
      correlation_id: Keyword.fetch!(options, :correlation_id),
      causation_id: Keyword.fetch!(options, :causation_id)
    }
    |> WorkEvent.create_changeset()
    |> Ecto.Changeset.put_change(:inserted_at, @inserted_at)
    |> Repo.insert!()
  end

  defp insert_artifact!(mission, work_item, artifact_id) do
    %{
      artifact_id: artifact_id,
      work_item_id: work_item.id,
      mission_id: mission.id,
      kind: "test_evidence",
      digest: String.duplicate("a", 64),
      media_type: "application/json",
      location: "test://#{artifact_id}",
      size_bytes: 0,
      provenance: %{"source" => "resource-test"},
      retention: %{}
    }
    |> Artifact.create_changeset()
    |> Ecto.Changeset.put_change(:inserted_at, @inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, @inserted_at)
    |> Repo.insert!()
  end

  defp padded_id(prefix, index) do
    "#{prefix}-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp context_body(work_item) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{},
      "recipe" => %{"name" => "resource-test", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"id" => "source-r1"},
      "workspace_revision" => %{"git" => "abc123"}
    }
  end

  defp cleanup! do
    TestHelpers.truncate_work!()
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(Asks.Ask)
    Repo.delete_all(Gates.Gate)
  end
end
