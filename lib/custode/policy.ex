defmodule Custode.Policy do
  @moduledoc """
  The policy layer (issue #50): fleet rules declared once as data, enforced
  at every surface that can hold them.

    1. **Prompt** (now): every applicable policy renders into a binding
      "## Policies" section of the composed system prompt -- generated from
      the same declarations, so the prose can never drift from the policy.
    2. **Review-time** (now): the gate card on the agent page names the
      policies that bind the proposing agent, so the approver reviews
      against the rule instead of from memory.
    3. **Mechanical** (later, #10): when an action passes through a verb
      tool we own (open_pr, merge_pr), the tool checks the same
      declarations and refuses or gates. Rules become code exactly as fast
      as verbs exist.

  A policy is `%{id, applies, text}` (+ optional `value` for parameterized
  rules like merge mode). `applies` scopes it: `:all`, or a selector list
  (`[tag: :external]`, `[repo: "owner/name"]`, `[role: :backlog_worker]`)
  where ANY selector matching the routine binds the policy.
  """

  @doc "All configured policies, normalized."
  def all do
    for policy <- Application.get_env(:custode, :policies, []) do
      %{
        id: Map.fetch!(policy, :id),
        applies: Map.get(policy, :applies, :all),
        text: Map.fetch!(policy, :text),
        value: Map.get(policy, :value)
      }
    end
  end

  @doc "The policies binding one normalized routine."
  def for_routine(routine) do
    Enum.filter(all(), &applies?(&1.applies, routine))
  end

  @doc "The binding policy ids for a routine (the gate card's chips)."
  def ids_for(routine), do: Enum.map(for_routine(routine), &to_string(&1.id))

  @doc """
  The prompt section for a routine: a binding rules list rendered from the
  declarations, or "" when none apply.
  """
  def render(routine) do
    case for_routine(routine) do
      [] ->
        ""

      policies ->
        rules = Enum.map_join(policies, "\n", &("- [" <> to_string(&1.id) <> "] " <> &1.text))

        """

        ## Policies (binding, non-negotiable)

        #{rules}
        """
    end
  end

  @doc """
  Does a scope bind this routine?

  The scope language is `:all` or a selector list (`[tag: :external]`,
  `[repo: "owner/name"]`, `[role: :backlog_worker]`) where ANY selector
  matching binds; `[]` therefore binds nothing.

  Public because it is the fleet's one way to say "which routines does this
  apply to". The ambient-orders gate (#19) scopes itself with this language
  rather than inventing a second one.
  """
  def applies?(:all, _routine), do: true

  def applies?(selectors, routine) when is_list(selectors) do
    Enum.any?(selectors, &selector_match?(&1, routine))
  end

  defp selector_match?({:tag, tag}, routine), do: tag in routine.tags
  defp selector_match?({:repo, repo}, routine), do: routine.repo == repo
  defp selector_match?({:role, role}, routine), do: routine.role == role
end
