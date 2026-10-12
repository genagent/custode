defmodule Custode.MCPAttachmentTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.MCP.AttachmentTools
  alias Custode.MCP.CallContext
  alias Custode.MCP.Identity
  alias Custode.MCP.Snodo, as: SnodoTransport
  alias Custode.MCP.ToolPolicy
  alias Custode.MCP.Tools
  alias Custode.Operator.Attachments
  alias Custode.OperatorMessage
  alias Custode.Repo

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )
  @tools ~w(attachment_upload attachment_read)

  setup do
    worker = uid("attachment-worker")
    other = uid("attachment-other")
    caretaker = uid("attachment-caretaker")
    ids = [worker, other, caretaker]

    put_env!(
      :routines,
      for id <- ids do
        %{
          id: id,
          role: if(id == caretaker, do: :caretaker, else: :backlog_worker),
          provider: :claude,
          cron: :manual,
          workspace: tmp_workspace!(),
          prompt: "fixture only",
          on_note: :ignore
        }
      end
    )

    on_exit(fn ->
      for id <- ids, do: ObanClaude.Agent.stop_agent(id)

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.agent_id')", j.meta) in ^ids
        )
      )

      Repo.delete_all(from(m in OperatorMessage, where: m.target_agent_id in ^ids))
      for id <- ids, do: Repo.query!("DELETE FROM operator_attachments WHERE agent_id = ?", [id])
    end)

    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false
    %{worker: worker, other: other, caretaker: caretaker}
  end

  test "direct handlers and attachment prompts require a verified operator", ctx do
    for actor <- [
          nil,
          %{},
          %{kind: :operator, id: ""},
          %{kind: :routine, id: ctx.caretaker},
          %{kind: :sub_agent, id: uid("helper")}
        ] do
      frame = %CallContext{assigns: %{custode_identity: actor}}

      calls = [
        {AttachmentTools.Upload,
         %{agent_id: ctx.worker, media_type: "image/png", data_base64: Base.encode64(@png)}},
        {AttachmentTools.Read, %{attachment_id: "unknown"}},
        {Tools.PromptAgent,
         %{agent_id: ctx.worker, prompt: "do not drop image", attachment_id: "unknown"}}
      ]

      for {module, params} <- calls do
        assert {:reply, %Snodo.Result{kind: :error, value: message}, ^frame} =
                 module.execute(params, frame)

        assert message == Attachments.error_message(:human_identity_required)
      end
    end

    assert Repo.all(from(m in OperatorMessage, where: m.target_agent_id == ^ctx.worker)) == []
    assert :offline = Custode.Agents.live_provider(ctx.worker)
    for name <- @tools, do: assert(ToolPolicy.fetch(name) == {:ok, :operator})
  end

  for protocol <- ["2025-11-25", "2026-07-28"] do
    @protocol protocol

    test "owned attachment upload, read and prompt correlation over HTTP #{@protocol}", ctx do
      actor = %{kind: :operator, id: uid("attachment-human")}
      token = Identity.mint(actor.kind, actor.id)
      initialize(token, @protocol)
      discovered = discover(token, @protocol)

      for {name, module} <- [
            {"attachment_upload", AttachmentTools.Upload},
            {"attachment_read", AttachmentTools.Read}
          ] do
        tool = Enum.find(discovered, &(&1["name"] == name))
        assert tool["inputSchema"] == module.input_schema()
        assert tool["outputSchema"]["properties"] == module.output_schema()["properties"]
        assert tool["outputSchema"]["additionalProperties"] == false
      end

      args = %{
        "agent_id" => ctx.worker,
        "media_type" => "image/png",
        "data_base64" => Base.encode64(@png)
      }

      attachment = call(token, @protocol, "attachment_upload", args) |> structured()
      assert attachment["agent_id"] == ctx.worker
      assert attachment["byte_count"] == byte_size(@png)
      assert attachment["media_type"] == "image/png"
      assert attachment["sha256"] == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
      assert is_binary(attachment["retention"])
      assert {:ok, _date, 0} = DateTime.from_iso8601(attachment["created_at"])
      refute Map.has_key?(attachment, "path")
      refute Map.has_key?(attachment, "data_base64")
      assert :offline = Custode.Agents.live_provider(ctx.worker)

      assert call(token, @protocol, "attachment_upload", args) |> structured() == attachment
      read_args = %{"attachment_id" => attachment["attachment_id"]}
      read = call(token, @protocol, "attachment_read", read_args) |> structured()
      assert Map.delete(read, "data_base64") == attachment
      assert Base.decode64!(read["data_base64"]) == @png

      prompt = %{
        "agent_id" => ctx.worker,
        "prompt" => "",
        "attachment_id" => attachment["attachment_id"],
        "idempotency_key" => uid("image-only")
      }

      receipt = call(token, @protocol, "prompt_agent", prompt) |> text_json()
      assert receipt["attachment_id"] == attachment["attachment_id"]
      assert receipt["delivered"] == true
      assert receipt["duplicate"] == false
      stored = Custode.OperatorMessages.get(receipt["message_id"])
      assert stored.attachment_id == attachment["attachment_id"]
      assert stored.caller_id == actor.id
      assert stored.target_agent_id == ctx.worker
      assert stored.prompt =~ "attached image:"
      assert [job] = jobs(ctx.worker)
      assert job.args["prompt"] =~ "attached image:"
      assert job.meta["correlation_id"] == stored.provider_correlation_id

      retry = call(token, @protocol, "prompt_agent", prompt) |> text_json()
      assert retry["message_id"] == receipt["message_id"]
      assert retry["attachment_id"] == attachment["attachment_id"]
      assert retry["duplicate"] == true
      assert length(jobs(ctx.worker)) == 1

      changed =
        call(token, @protocol, "attachment_upload", %{
          args
          | "data_base64" => Base.encode64(@png <> "changed")
        })
        |> structured()

      assert_error(
        call(token, @protocol, "prompt_agent", %{
          prompt
          | "attachment_id" => changed["attachment_id"]
        })
      )

      assert length(jobs(ctx.worker)) == 1

      # A busy target queues text and its image as the same durable message.
      queued =
        call(token, @protocol, "prompt_agent", %{
          prompt
          | "prompt" => "inspect next",
            "idempotency_key" => uid("queued-image")
        })
        |> text_json()

      assert queued["how"] == "queued"
      assert queued["attachment_id"] == attachment["attachment_id"]
      assert Custode.OperatorMessages.get(queued["message_id"]).prompt =~ "inspect next"
      assert length(jobs(ctx.worker)) == 1

      other_token = Identity.mint(:operator, uid("other-human"))
      initialize(other_token, @protocol)
      assert_error(call(other_token, @protocol, "attachment_read", read_args))

      assert_error(
        call(other_token, @protocol, "prompt_agent", %{
          prompt
          | "idempotency_key" => uid("foreign-image")
        })
      )

      assert_error(
        call(token, @protocol, "prompt_agent", %{
          prompt
          | "agent_id" => ctx.other,
            "idempotency_key" => uid("wrong-target")
        })
      )

      assert :offline = Custode.Agents.live_provider(ctx.other)

      # Legacy optional null keys still mean a new text-only message.
      plain =
        call(token, @protocol, "prompt_agent", %{
          "agent_id" => ctx.other,
          "prompt" => "legacy null idempotency key",
          "idempotency_key" => nil
        })
        |> text_json()

      assert plain["delivered"] == true
      assert plain["attachment_id"] == nil
      assert length(jobs(ctx.other)) == 1
    end

    test "upload envelope and refusals stay bounded over HTTP #{@protocol}", ctx do
      token = Identity.mint(:operator, uid("attachment-human"))
      initialize(token, @protocol)

      args = %{
        "agent_id" => ctx.worker,
        "media_type" => "image/png",
        "data_base64" => Base.encode64(@png)
      }

      # Header validation is deliberate; this is not a full image decoder proof.
      large = @png <> :binary.copy(<<0>>, 2_100_000)
      large_args = %{args | "data_base64" => Base.encode64(large)}
      assert byte_size(Jason.encode!(large_args)) > 2_000_000
      receipt = call(token, @protocol, "attachment_upload", large_args) |> structured()
      assert receipt["byte_count"] == byte_size(large)
      assert :offline = Custode.Agents.live_provider(ctx.worker)

      oversized = @png <> :binary.copy(<<0>>, 10_000_001 - byte_size(@png))

      assert_error(
        call(token, @protocol, "attachment_upload", %{
          args
          | "data_base64" => Base.encode64(oversized)
        })
      )

      for invalid <- ["not base64!", Base.encode64("not an image")] do
        assert_error(
          call(token, @protocol, "attachment_upload", %{args | "data_base64" => invalid})
        )
      end

      assert_error(
        call(token, @protocol, "attachment_upload", %{args | "media_type" => "image/jpeg"})
      )

      assert_error(call(token, @protocol, "attachment_read", %{"attachment_id" => "missing"}))

      for invalid <- [
            Map.put(args, "path", "/tmp/not-authority.png"),
            %{args | "media_type" => "text/plain"},
            %{args | "agent_id" => ""}
          ] do
        assert_invalid(
          post(token, @protocol, "tools/call", %{
            "name" => "attachment_upload",
            "arguments" => invalid
          })
        )
      end

      assert_invalid(
        post(token, @protocol, "tools/call", %{
          "name" => "prompt_agent",
          "arguments" => %{
            "agent_id" => ctx.worker,
            "prompt" => "must not send",
            "attachment_id" => nil
          }
        })
      )

      for name <- @tools do
        routine_token = Identity.mint(:routine, ctx.caretaker)
        initialize(routine_token, @protocol)
        refute name in Enum.map(discover(routine_token, @protocol), & &1["name"])

        arguments =
          if name == "attachment_upload",
            do: args,
            else: %{"attachment_id" => receipt["attachment_id"]}

        assert_refused(call(routine_token, @protocol, name, arguments))

        assert post(nil, @protocol, "tools/call", %{"name" => name, "arguments" => arguments}).status ==
                 401
      end

      routine_token = Identity.mint(:routine, ctx.caretaker)

      assert_error(
        call(routine_token, @protocol, "prompt_agent", %{
          "agent_id" => ctx.worker,
          "prompt" => "do not drop this",
          "attachment_id" => receipt["attachment_id"]
        })
      )

      assert Repo.all(from(m in OperatorMessage, where: m.target_agent_id == ^ctx.worker)) == []
      assert jobs(ctx.worker) == []
      assert SnodoTransport.plug_options()["/mcp"].max_body_bytes == 14_000_000
      assert SnodoTransport.plug_options()["/mcp/memory"].max_body_bytes == 2_000_000
    end
  end

  defp structured(response) do
    assert %{
             "result" => %{
               "isError" => false,
               "structuredContent" => value,
               "content" => [%{"text" => text}]
             }
           } = response

    assert Jason.decode!(text) == value
    value
  end

  defp text_json(response) do
    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = response
    Jason.decode!(text)
  end

  defp assert_error(response), do: assert(match?(%{"result" => %{"isError" => true}}, response))
  defp assert_refused(%{"error" => _error}), do: :ok
  defp assert_refused(response), do: assert_error(response)

  defp assert_invalid(response) do
    assert response.status in [200, 400]

    assert match?(%{"error" => %{"code" => -32_602}}, response.body) or
             match?(%{"result" => %{"isError" => true}}, response.body)
  end

  defp jobs(agent_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "ObanClaude.Agent.Job",
        where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^agent_id,
        order_by: [asc: j.id]
      )
    )
  end

  defp initialize(token, "2025-11-25" = protocol) do
    response =
      post(token, nil, "initialize", %{
        "protocolVersion" => protocol,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "attachment-fixture", "version" => "1"}
      })

    assert response.status == 200
  end

  defp initialize(_token, _protocol), do: :ok

  defp discover(token, protocol, params \\ %{}) do
    response = post(token, protocol, "tools/list", params)
    assert response.status == 200
    page = response.body["result"]

    case page["nextCursor"] do
      nil -> page["tools"]
      cursor -> page["tools"] ++ discover(token, protocol, %{"cursor" => cursor})
    end
  end

  defp call(token, protocol, name, arguments) do
    response = post(token, protocol, "tools/call", %{"name" => name, "arguments" => arguments})
    assert response.status == 200
    response.body
  end

  defp post(token, protocol, method, params) do
    headers = [{"accept", "application/json, text/event-stream"}]
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers
    headers = if protocol, do: [{"mcp-protocol-version", protocol} | headers], else: headers
    {headers, params} = modern_request(protocol, method, headers, params)

    Req.post!(Custode.MCP.url(),
      json: %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      headers: headers,
      retry: false,
      receive_timeout: 20_000
    )
  end

  defp modern_request("2026-07-28" = protocol, method, headers, params) do
    headers = [{"mcp-method", method} | headers]

    headers =
      if method == "tools/call", do: [{"mcp-name", params["name"]} | headers], else: headers

    params =
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => protocol,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    {headers, params}
  end

  defp modern_request(_protocol, _method, headers, params), do: {headers, params}
end
