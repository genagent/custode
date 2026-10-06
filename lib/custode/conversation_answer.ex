defmodule Custode.ConversationAnswer do
  @moduledoc """
  Separates conversational prose from a turn's report and action directives.

  An explicit answer key is authoritative, including null or blank answers.
  Results written before that field existed retain their legacy prose fallback.
  The feed uses only explicit structured answers to avoid echoing legacy summary
  text or raw directive JSON. Durable conversation reads keep the full answer.
  """

  @doc "Read a full answer, with compatibility for historical structured output."
  def from_output(%{"answer" => answer}), do: prose(answer)

  def from_output(%{"directive" => "ask_user", "question" => text}) when is_binary(text),
    do: prose(text)

  def from_output(%{"directive" => "request_permission", "action" => text})
      when is_binary(text),
      do: prose(text)

  def from_output(%{"summary" => text}), do: prose(text)
  def from_output(output), do: prose(output)

  @doc "Read only an explicit structured answer; summaries are not feed responses."
  def explicit(%{"answer" => answer}), do: prose(answer)
  def explicit(_output), do: nil

  defp prose(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp prose(_output), do: nil
end
