defmodule Custode.WorkAgreementToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.CallContext, as: Frame
  alias Custode.MCP.WorkAgreementTools
  alias Custode.MCP.WorkAgreementTools.{Checkpoint, Create, Read, Resolve, Revise, Submit}

  @operator %Frame{assigns: %{custode_identity: %{kind: :operator, id: "agreement-operator"}}}
  @tools [Create, Revise, Checkpoint, Submit, Resolve, Read]

  setup do
    owner = uid("agreement-owner")
    other = uid("agreement-other")
    caretaker = uid("agreement-caretaker")

    put_env!(
      :routines,
      for {id, role} <- [
            {owner, :backlog_worker},
            {other, :backlog_worker},
            {caretaker, :caretaker}
          ] do
        %{id: id, role: role, cron: :manual, workspace: tmp_workspace!(), prompt: "fixture only"}
      end
    )

    %{owner: owner, other: other, caretaker: caretaker}
  end

  test "all six tools round-trip attributed bookkeeping without starting work", ctx do
    args = create_args(ctx.owner)
    created = wire_json("work_agreement_create", args, frame(ctx.caretaker))
    id = created["agreement_id"]
    assert created["schema_version"] == "custode.work_agreement_mutation.v1"
    assert created["recorded_by"]["kind"] == "routine"
    assert created["recorded_by"]["id"] == ctx.caretaker
    assert created["revision"] == 1
    refute created["duplicate"]

    retry = wire_json("work_agreement_create", args, frame(ctx.caretaker))
    assert retry["duplicate"]
    assert retry["agreement_id"] == id
    assert retry["record_id"] == created["record_id"]

    checkpoint =
      wire_json(
        "work_agreement_checkpoint",
        %{
          "agreement_id" => id,
          "request_id" => uid("checkpoint"),
          "expected_revision" => 1,
          "summary" => "Examined available evidence",
          "next_steps" => [%{"id" => "review", "text" => "Review the negative finding"}],
          "blockers" => [],
          "decisions" => []
        },
        frame(ctx.owner)
      )

    assert checkpoint["kind"] == "checkpoint"
    assert checkpoint["recorded_by"]["id"] == ctx.owner

    submission = wire_json("work_agreement_submit", submission_args(id), frame(ctx.owner))
    assert submission["kind"] == "submission"

    resolution =
      wire_json("work_agreement_resolve", resolution_args(id, submission["record_id"]), @operator)

    assert resolution["kind"] == "resolution"
    assert resolution["recorded_by"]["kind"] == "operator"
    assert resolution["recorded_by"]["id"] == "agreement-operator"

    accepted = wire_json("work_agreement_read", %{"agreement_id" => id}, frame(ctx.owner))
    assert accepted["schema_version"] == "custode.work_agreement.v1"
    assert accepted["current"]["status"] == "accepted"
    assert accepted["current"]["submission"]["payload"]["outputs"] == []
    assert accepted["current"]["intent"]["inputs"] == args["intent"]["inputs"]

    revised =
      wire_json(
        "work_agreement_revise",
        %{
          "agreement_id" => id,
          "request_id" => uid("revise"),
          "expected_revision" => 1,
          "intent" => Map.put(args["intent"], "outcome", "Check the next sample")
        },
        frame(ctx.caretaker)
      )

    assert revised["revision"] == 2

    current = wire_json("work_agreement_read", %{"agreement_id" => id, "limit" => 1}, @operator)
    assert current["current"]["status"] == "open"
    assert current["current"]["resolution"] == nil
    assert current["history"]["has_more"]

    previous =
      wire_json(
        "work_agreement_read",
        %{
          "agreement_id" => id,
          "before_sequence" => current["history"]["before_sequence"]
        },
        @operator
      )

    assert previous["current_revision"] == 2
    assert Enum.any?(previous["history"]["records"], &(&1["kind"] == "resolution"))

    listed = wire_json("work_agreement_read", %{"routine_id" => ctx.owner}, frame(ctx.caretaker))
    assert listed["schema_version"] == "custode.work_agreement_list.v1"
    assert [%{"agreement_id" => ^id}] = listed["agreements"]
    assert Custode.InboxWakes.get(ctx.owner) == nil
    assert Custode.OperatorMessages.queued_for(ctx.owner) == []
  end

  test "direct adapters enforce owner, manager and human boundaries", ctx do
    created = Create.execute(create_args(ctx.owner), @operator) |> tool_json()
    id = created["agreement_id"]

    checkpoint = %{
      "agreement_id" => id,
      "request_id" => uid("checkpoint"),
      "expected_revision" => 1,
      "summary" => "Owner assessment"
    }

    assert Create.execute(create_args(ctx.owner), frame(ctx.owner)) |> tool_error() != ""

    assert Revise.execute(
             %{
               "agreement_id" => id,
               "request_id" => uid("revise"),
               "expected_revision" => 1,
               "intent" => intent()
             },
             frame(ctx.owner)
           )
           |> tool_error() != ""

    assert Checkpoint.execute(checkpoint, frame(ctx.other)) |> tool_error() != ""
    assert Submit.execute(submission_args(id), frame(ctx.caretaker)) |> tool_error() != ""
    assert Read.execute(%{"agreement_id" => id}, frame(ctx.other)) |> tool_error() != ""

    submitted = Submit.execute(submission_args(id), frame(ctx.owner)) |> tool_json()

    for caller <- [frame(ctx.owner), frame(ctx.caretaker)] do
      assert Resolve.execute(resolution_args(id, submitted["record_id"]), caller) |> tool_error() !=
               ""
    end

    for tool <- @tools,
        caller <- [%Frame{}, frame("", :operator), frame(ctx.owner, :sub_agent)] do
      assert tool.execute(%{}, caller) |> tool_error() =~ "authenticated"
    end
  end

  test "strict native calls reject unknown top-level and nested fields before normalization",
       ctx do
    args = create_args(ctx.owner)
    actor = %{kind: :operator, id: "agreement-operator"}
    context = native_context(actor)
    unknown = "unknown_" <> Base.encode16(:crypto.strong_rand_bytes(12))
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    for invalid <- [
          Map.put(args, unknown, "must not disappear"),
          Map.put(args, "actor", %{"kind" => "operator", "id" => "spoof"}),
          put_in(args, ["intent", unknown], "must not disappear"),
          put_in(args, ["intent", "criteria"], [
            %{"id" => "negative", "text" => "Report evidence", unknown => true}
          ]),
          put_in(args, ["intent", "inputs"], [
            %{"kind" => "document", "value" => "opaque:source", unknown => true}
          ])
        ] do
      assert {:error, %Snodo.Error{code: -32_602, data: data}} = Create.call(invalid, context)
      assert data["keyword"] == "additionalProperties"
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    listed = Read.execute(%{routine_id: ctx.owner}, @operator) |> tool_json()
    assert listed["agreements"] == []

    assert Create.execute(Map.put(args, :request_id, args["request_id"]), @operator)
           |> tool_error() =~ "invalid"
  end

  test "read selectors and pagination cannot silently select a different scope", ctx do
    created = Create.execute(create_args(ctx.owner), @operator) |> tool_json()
    id = created["agreement_id"]

    for args <- [
          %{},
          %{"agreement_id" => id, "routine_id" => ctx.owner},
          %{"agreement_id" => id, "before_id" => id},
          %{"routine_id" => ctx.owner, "before_sequence" => 1}
        ] do
      assert Read.execute(args, @operator) |> tool_error() =~ "exactly one"
    end

    context = native_context(%{kind: :operator, id: "operator"})

    for limit <- [0, 101, 1.5] do
      assert {:error, %Snodo.Error{code: -32_602}} =
               Read.call(%{"agreement_id" => id, "limit" => limit}, context)
    end

    assert WorkAgreementTools.schema(:read)["additionalProperties"] == false
  end

  defp native_context(actor) do
    %Snodo.Context{
      auth: %{identity: actor, origin: :mcp},
      protocol_version: "2025-06-18",
      protocol: Snodo.Protocol.V2025_06_18,
      transport: %Snodo.Transport.Context{}
    }
  end

  defp create_args(owner),
    do: %{"request_id" => uid("create"), "routine_id" => owner, "intent" => intent()}

  defp intent do
    %{
      "outcome" => "Determine whether available evidence supports the proposal",
      "criteria" => [%{"id" => "negative", "text" => "Record a supported conclusion and limits"}],
      "assignment_id" => "sample-review",
      "boundaries" => ["Read only"],
      "inputs" => [
        %{
          "kind" => "document",
          "value" => "opaque:source",
          "revision" => "r1",
          "label" => "Source receipt"
        }
      ]
    }
  end

  defp submission_args(id) do
    %{
      "agreement_id" => id,
      "request_id" => uid("submission"),
      "agreement_revision" => 1,
      "assignment_id" => "sample-review",
      "summary" => "Evidence does not support the proposal",
      "outputs" => [],
      "criterion_evidence" => [
        %{
          "criterion_id" => "negative",
          "references" => [],
          "note" => "The supplied sample contradicts the proposal"
        }
      ],
      "verification_limits" => "Only the supplied sample was assessed"
    }
  end

  defp resolution_args(id, submission_id),
    do: %{
      "agreement_id" => id,
      "request_id" => uid("resolve"),
      "expected_revision" => 1,
      "submission_id" => submission_id,
      "outcome" => "accepted",
      "reason" => "Negative finding satisfies the criterion"
    }

  defp frame(id, kind \\ :routine),
    do: %Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}

  defp wire_json(name, args, frame) do
    assert {:reply, %{"isError" => false, "content" => [%{"text" => text} | _]}, _} =
             mcp_dispatch("tools/call", %{"name" => name, "arguments" => args}, frame)

    Jason.decode!(text)
  end
end
