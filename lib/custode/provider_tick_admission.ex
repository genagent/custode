defmodule Custode.ProviderTickAdmission do
  @moduledoc """
  Serializes a provider Tick's final status/start/delivery step with live
  routine configuration changes.

  Both provider packages call this optional host hook immediately before they
  inspect or mutate their agent process. The embedded provider and delivery
  revision must still match Custode's current roster after the handoff fence
  is open, otherwise the old beat is cancelled without reaching a provider.
  """

  alias Custode.{AgentHandoff, ConversationArcs}

  @doc false
  def admit(provider, agent_id, delivery_revision, deliver)
      when provider in [:claude, :codex] and is_binary(agent_id) and is_function(deliver, 0) do
    admit(provider, agent_id, delivery_revision, %{}, deliver)
  end

  @doc false
  def admit(provider, agent_id, delivery_revision, context, deliver)
      when provider in [:claude, :codex] and is_binary(agent_id) and is_map(context) and
             is_function(deliver, 0) do
    result =
      AgentHandoff.admit(agent_id, deliver,
        expected_provider: provider,
        expected_delivery_revision: delivery_revision
      )

    case result do
      {:deferred, reason} ->
        cancel_without_launch(
          {:config_transition, agent_id, reason},
          agent_id,
          context,
          :config_transition
        )

      {:error, {:stale_execution_config, _expected, _current}} ->
        cancel_without_launch({:stale_tick, agent_id}, agent_id, context, :stale_tick)

      {:error, reason} ->
        cancel_without_launch(
          {:config_reconcile_failed, agent_id, reason},
          agent_id,
          context,
          :config_reconcile_failed
        )

      {:cancel, reason} ->
        cancel_without_launch(reason, agent_id, context, :provider_cancelled)

      admitted ->
        admitted
    end
  end

  defp cancel_without_launch(cancel_reason, agent_id, context, arc_reason) do
    case arc_id(context) do
      nil ->
        {:cancel, cancel_reason}

      arc_id ->
        case ConversationArcs.abandon(agent_id, arc_id, arc_reason) do
          {:ok, _arc_or_already_closed} ->
            {:cancel, cancel_reason}

          {:error, reason} ->
            {:cancel, {:arc_cleanup_failed, cancel_reason, reason}}
        end
    end
  end

  defp arc_id(%{arc_id: arc_id}) when is_binary(arc_id) and arc_id != "", do: arc_id
  defp arc_id(%{"arc_id" => arc_id}) when is_binary(arc_id) and arc_id != "", do: arc_id
  defp arc_id(_context), do: nil
end
