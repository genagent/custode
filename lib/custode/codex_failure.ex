defmodule Custode.CodexFailure do
  @moduledoc """
  Bounded public diagnostics for failed Codex command results.

  Only typed error messages and recognizable plain diagnostic lines are
  candidates. Other JSON events, command/configuration dumps and ordinary
  assistant output are not failure evidence. Credential-bearing suffixes
  are conservatively omitted before the final byte bound is applied.

  This projection does not classify failures or change retry policy.
  """

  @max_bytes 2048
  @truncated "\n[truncated]"
  @redacted "[credential-bearing diagnostic omitted]"
  @echo_omitted "[command/configuration detail omitted]"
  @fallback "Codex exited unsuccessfully without a diagnostic"

  @plain_diagnostic ~r/^(?:(?:error|fatal|failed|failure|invalid|unsupported|unauthorized|forbidden|denied|unavailable|refused|cannot|unable to|not supported|not found|not authenticated|timed out|connection reset|rate limit)\b|(?:api|codex)(?: command)? (?:error|failed)\b|\d{4}-\d{2}-\d{2}[T ][0-9:.+Z-]+\s+(?:ERROR|FATAL)\b)/iu
  @credential ~r/\b(?:authorization|proxy-authorization|bearer)\b|\b[a-z0-9_-]*(?:api[ _-]?key|access[ _-]?token|refresh[ _-]?token|client[ _-]?secret|password)\b|\b(?:[a-z0-9]+[_-])*token\b(?:\\?["'])?\s*[:=]/iu

  @echo ~r/\bcodex\s+(?:exec|review|e)\b|\b(?:prompt|system_prompt|developer_instructions|mcp_servers|argv)\b|\b(?:command|cmd|args|arguments|configuration|config|environment|shell)(?:\\?["'])?\s*[:=]/iu

  @doc "Project one failed command's exit code and safe diagnostic text."
  @spec detail(CodexWrapper.Result.t()) :: String.t()
  def detail(%CodexWrapper.Result{} = result) do
    stdout = scan(result.stdout)
    stderr = scan(result.stderr)

    message =
      stdout.failed || stderr.failed || stdout.error || stderr.error ||
        stderr.plain || stdout.plain || @fallback

    ("#{exit_label(result.exit_code)}: " <> redact(message))
    |> bound()
  end

  defp scan(value) do
    value
    |> clean()
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{failed: nil, error: nil, plain: nil}, &read_line/2)
  end

  defp read_line(line, evidence) do
    line = String.trim(line)

    case Jason.decode(line) do
      {:ok, %{"type" => "turn.failed", "error" => %{"message" => message}}} ->
        put_message(evidence, :failed, message)

      {:ok, %{"type" => "error", "message" => message}} ->
        put_message(evidence, :error, message)

      {:ok, _other_json} ->
        evidence

      {:error, _not_json} ->
        plain_line(line, evidence)
    end
  end

  defp put_message(evidence, field, message) when is_binary(message) do
    case message |> clean() |> String.trim() do
      "" -> evidence
      value -> Map.put(evidence, field, value)
    end
  end

  defp put_message(evidence, _field, _message), do: evidence

  defp plain_line(line, evidence) do
    if String.starts_with?(line, ["{", "[", "\""]) or
         not Regex.match?(@plain_diagnostic, line) do
      evidence
    else
      %{evidence | plain: line}
    end
  end

  defp clean(value) when is_binary(value) do
    value
    |> String.replace_invalid()
    |> String.replace(~r/\e\].*?(?:\a|\e\\|\z)/s, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F\x{0080}-\x{009F}]/u, "")
  end

  defp clean(_value), do: ""

  # Do not parse an arbitrary shell/JSON/TOML credential value and risk
  # retaining a quoted or multiline suffix. Keep only its preceding diagnosis.
  defp redact(message) do
    omission =
      [omission(message, @credential, @redacted), omission(message, @echo, @echo_omitted)]
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(&elem(&1, 0), fn -> nil end)

    case omission do
      {offset, replacement} -> binary_part(message, 0, offset) <> replacement
      nil -> message
    end
  end

  defp omission(message, pattern, replacement) do
    case Regex.run(pattern, message, return: :index) do
      [{offset, _length}] -> {offset, replacement}
      nil -> nil
    end
  end

  defp exit_label(code) when is_integer(code), do: "exit #{code}"
  defp exit_label(_code), do: "unknown exit"

  defp bound(text) when byte_size(text) <= @max_bytes, do: text

  defp bound(text) do
    prefix =
      text
      |> binary_part(0, @max_bytes - byte_size(@truncated))
      |> valid_prefix()

    prefix <> @truncated
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> valid_prefix()
  end
end
