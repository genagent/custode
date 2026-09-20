defmodule Custode.Gates.Grant do
  @moduledoc """
  Whether a write verb is inside what the caller was approved to do (#451).

  A gate was a conversational checkpoint and nothing more: the write verbs
  checked repository policy, and the tie between "the operator approved
  marking #490 ready" and "the turn marked #490 ready and nothing else" was a
  sentence in the charter. This is that tie as a check. An approved gate is a
  live grant from the decision until the agent next leaves `:running`
  (`Custode.Gates.active_grant/1`), and its class names the verbs inside it
  (`Custode.Gates.Class.verbs/1`).

  ## Modes

  `config :custode, gate_grant_mode: :observe` (the default) lets every verb
  run and records a `grant_outside` feed entry for one made outside a grant.
  `:enforce` refuses it, naming the rule. Observe first on purpose: refusing
  today would be a guess about how the fleet behaves, and the observations
  are what the class-to-verb table gets corrected against.

  The operator is never checked. Neither is shell: an approved continuation
  can run `gh` itself, which no MCP check sees. That bound is the engine's.
  """

  alias Custode.Gates
  alias Custode.Gates.Class

  @type verdict :: :within | :unbounded | :outside_class | :no_grant

  @doc "`:observe` or `:enforce`."
  @spec mode() :: :observe | :enforce
  def mode, do: Application.get_env(:custode, :gate_grant_mode, :observe)

  @doc """
  The verdict for `agent_id` calling `verb` right now, with the grant it was
  judged against. Pure apart from the one read of the live grant.
  """
  @spec verdict(String.t(), atom()) :: {verdict(), Gates.grant() | nil}
  def verdict(agent_id, verb) when is_binary(agent_id) and is_atom(verb) do
    case Gates.active_grant(agent_id) do
      nil -> {:no_grant, nil}
      %{class: class} = grant -> {judge(Class.verbs(class), verb), grant}
    end
  end

  defp judge(:any, _verb), do: :unbounded
  defp judge(verbs, verb), do: if(verb in verbs, do: :within, else: :outside_class)

  @doc """
  Check a write verb. `nil` is the operator, who is never checked. Returns
  `:ok` to proceed, or `{:error, message}` in `:enforce` mode with the rule
  named so the agent can quote it.
  """
  @spec check(String.t() | nil, atom()) :: :ok | {:error, String.t()}
  def check(nil, _verb), do: :ok

  def check(agent_id, verb) do
    case verdict(agent_id, verb) do
      {inside, _grant} when inside in [:within, :unbounded] -> :ok
      {outside, grant} -> outside(mode(), agent_id, verb, outside, grant)
    end
  end

  @doc """
  What has been observed outside a grant, most frequent first: one row per
  agent, verb and verdict, from the most recent 500 `grant_outside` entries.
  This is the evidence the class-to-verb table is corrected against before
  `:enforce` is turned on.
  """
  @spec observations() :: [
          %{agent: String.t(), verb: String.t(), verdict: String.t(), count: pos_integer()}
        ]
  def observations do
    "grant_outside"
    |> Custode.Feed.recent_by_event(limit: 500)
    |> Enum.frequencies_by(&{&1["agent"], &1["verb"], &1["verdict"]})
    |> Enum.map(fn {{agent, verb, verdict}, count} ->
      %{agent: agent, verb: verb, verdict: verdict, count: count}
    end)
    |> Enum.sort_by(&{-&1.count, &1.agent, &1.verb})
  end

  defp outside(mode, agent_id, verb, verdict, grant) do
    Custode.Feed.record(%{
      event: "grant_outside",
      agent: agent_id,
      verb: to_string(verb),
      verdict: to_string(verdict),
      class: grant && grant.class,
      gate_id: grant && grant.gate_id,
      refused: mode == :enforce,
      summary: summary(verb, verdict, grant)
    })

    if mode == :enforce, do: {:error, "gate grant: " <> summary(verb, verdict, grant)}, else: :ok
  end

  defp summary(verb, :no_grant, _grant),
    do: "#{verb} with no approved action in flight -- raise request_permission first"

  defp summary(verb, :outside_class, %{class: class, gate_id: gate_id}),
    do: "#{verb} is outside what gate #{gate_id} approved (class #{class})"
end
