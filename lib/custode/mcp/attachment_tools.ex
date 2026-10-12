defmodule Custode.MCP.AttachmentTools do
  @moduledoc false

  alias Custode.MCP.Tools
  alias Custode.Operator.Attachments

  @max_base64_bytes 13_333_336
  @media_types ~w(image/png image/jpeg image/gif image/webp)
  @public_fields ~w(attachment_id agent_id media_type byte_count sha256 retention created_at)a

  def upload_input do
    object(%{
      "agent_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024},
      "media_type" => %{"type" => "string", "enum" => @media_types},
      "data_base64" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_base64_bytes}
    })
  end

  def read_input do
    object(%{"attachment_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}})
  end

  def output(mode) do
    properties = %{
      "attachment_id" => %{"type" => "string"},
      "agent_id" => %{"type" => "string"},
      "media_type" => %{"type" => "string", "enum" => @media_types},
      "byte_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 10_000_000},
      "sha256" => %{"type" => "string", "minLength" => 64, "maxLength" => 64},
      "retention" => %{"type" => "string"},
      "created_at" => %{"type" => "string"}
    }

    properties =
      if mode == :read,
        do:
          Map.put(properties, "data_base64", %{
            "type" => "string",
            "maxLength" => @max_base64_bytes
          }),
        else: properties

    object(properties)
  end

  def verified_operator(frame) do
    case frame.assigns[:custode_identity] do
      %{kind: :operator, id: id} = actor when is_binary(id) and id != "" -> {:ok, actor}
      _missing_or_nonhuman -> {:error, :human_identity_required}
    end
  end

  def upload(params, frame) do
    with {:ok, actor} <- verified_operator(frame),
         {:ok, bytes} <- decode(params.data_base64),
         {:ok, attachment} <- Attachments.upload(actor, params.agent_id, params.media_type, bytes) do
      success(frame, attachment, :upload)
    else
      {:error, reason} -> refusal(frame, reason)
    end
  end

  def read(params, frame) do
    with {:ok, actor} <- verified_operator(frame),
         {:ok, attachment} <- Attachments.read(actor, params.attachment_id) do
      success(frame, attachment, :read)
    else
      {:error, reason} -> refusal(frame, reason)
    end
  end

  def refusal(frame, reason), do: Tools.fail(frame, Attachments.error_message(reason))

  defp decode(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_base64_bytes do
    case Base.decode64(encoded) do
      {:ok, bytes} when byte_size(bytes) <= 10_000_000 -> {:ok, bytes}
      {:ok, _oversize} -> {:error, :too_large}
      :error -> {:error, :invalid_image}
    end
  end

  defp decode(_encoded), do: {:error, :too_large}

  defp success(frame, attachment, mode) do
    fields = if mode == :read, do: [:data_base64 | @public_fields], else: @public_fields
    result = Map.new(fields, &{Atom.to_string(&1), Map.fetch!(attachment, &1)})
    {:reply, Snodo.Result.structured(result), frame}
  end

  defp object(properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => Map.keys(properties),
      "properties" => properties
    }
  end
end

defmodule Custode.MCP.AttachmentTools.Upload do
  @moduledoc "Upload one bounded PNG, JPEG, GIF or WebP image for a configured routine as its verified human operator. Returns an owned attachment reference for prompt_agent; uploading does not start work. The server validates size and image header, not full codec validity."
  use Custode.MCP.Tool, name: "attachment_upload", strict_arguments: true
  alias Custode.MCP.AttachmentTools
  input_schema(AttachmentTools.upload_input())
  output_schema(AttachmentTools.output(:upload))
  @impl true
  def execute(params, frame), do: AttachmentTools.upload(params, frame)
end

defmodule Custode.MCP.AttachmentTools.Read do
  @moduledoc "Read an image by its server-owned attachment reference as the same verified human operator who uploaded it. Returns bounded metadata and Base64 bytes, never a selectable filesystem path. Reading does not start work."
  use Custode.MCP.Tool, name: "attachment_read", strict_arguments: true
  alias Custode.MCP.AttachmentTools
  input_schema(AttachmentTools.read_input())
  output_schema(AttachmentTools.output(:read))
  @impl true
  def execute(params, frame), do: AttachmentTools.read(params, frame)
end
