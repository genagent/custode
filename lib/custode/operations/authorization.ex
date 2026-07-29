defmodule Custode.Operations.Authorization do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationEnvelope}

  @spec operator(OperationDefinition.t(), OperationEnvelope.t()) ::
          {:ok, :operator} | {:error, {:denied, term()}}
  def operator(_definition, %OperationEnvelope{actor: %{kind: :operator}}), do: {:ok, :operator}

  def operator(_definition, %OperationEnvelope{actor: %{kind: :routine, id: id}}) do
    with %{role: role} <- Custode.Routine.get(id),
         :operator <- Custode.Roles.grants(role) do
      {:ok, :operator}
    else
      _not_operator -> {:error, {:denied, :operator_required}}
    end
  end

  def operator(_definition, _envelope), do: {:error, {:denied, :operator_required}}

  @spec operator_or_system(OperationDefinition.t(), OperationEnvelope.t()) ::
          {:ok, :operator | :system} | {:error, {:denied, term()}}
  def operator_or_system(_definition, %OperationEnvelope{actor: %{kind: :system}}),
    do: {:ok, :system}

  def operator_or_system(definition, envelope), do: operator(definition, envelope)

  @spec system(OperationDefinition.t(), OperationEnvelope.t()) ::
          {:ok, :system} | {:error, {:denied, term()}}
  def system(_definition, %OperationEnvelope{actor: %{kind: :system}}), do: {:ok, :system}
  def system(_definition, _envelope), do: {:error, {:denied, :system_required}}
end
