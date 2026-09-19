defmodule Custode.Host do
  @moduledoc """
  What the running node knows about the health of the host it runs on (#443).

  The boot doctor (`Custode.MCP.Probe`) checks that the `claude` binary is
  present and authenticated, and withholds the `:ticks` queue when it is not.
  Withholding is the right call and used to be the end of it: one feed entry,
  then a fleet that looked alive (sensors firing, every agent `scheduled`)
  while no turn could ever run. On 2026-09-14 that went on for three days and
  read to the operator as "stuck".

  This module is the fact the resolver and the page chrome need in order to
  say so. It is written once per boot and read on every render, which is what
  `:persistent_term` is for.

  `:unknown` is distinct from `{:ok, _}`: a node whose probe has not finished
  (or a test env with no ticks queue) has not passed the doctor, and nothing
  should claim it has.
  """

  @key {__MODULE__, :doctor}

  @type doctor :: :unknown | {:ok, DateTime.t()} | {:failed, String.t(), DateTime.t()}

  @doc "Record the boot doctor's result."
  @spec put_doctor(:ok | {:failed, String.t()}, DateTime.t()) :: :ok
  def put_doctor(result, now \\ DateTime.utc_now())

  def put_doctor(:ok, now), do: :persistent_term.put(@key, {:ok, now})

  def put_doctor({:failed, report}, now) when is_binary(report),
    do: :persistent_term.put(@key, {:failed, report, now})

  @doc "The last boot doctor result."
  @spec doctor() :: doctor()
  def doctor, do: :persistent_term.get(@key, :unknown)

  @doc "Forget the result. For tests."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @doc "The facts `Custode.Attention.host/1` resolves."
  @spec facts() :: %{doctor: doctor()}
  def facts, do: %{doctor: doctor()}
end
