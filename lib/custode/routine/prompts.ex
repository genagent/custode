defmodule Custode.Routine.Prompts do
  @moduledoc """
  The composed standing orders for each routine role, layered per the
  vocabulary of issue #38:

    * **charter** -- what EVERY custode routine agent is: the environment
      (scheduled sweeps, fresh sessions, nobody watching), the
      notebook/memory contract, the inbox discipline, the directive
      protocol, and the safety floor. One source; a fix here fixes every
      role at once.
    * **role** -- the job loop only: caretaker, repo_caretaker,
      backlog_worker, star_tracker, contributor_watch. Role bodies must not
      restate charter material.
    * **assignment** -- the instance values injected where they belong
      (routine_id today; more via config as #41 unfolds).

  `for_role/2` returns `charter <> role`. A routine's `system_prompt:`
  config still overrides the whole composition.

  ## Where the text lives (#269, design/003 D4)

  The bodies are packaged assets under `priv/prompts/*.md`, read through
  `Custode.Assets`. This module composes them; it no longer carries them.

  Two things that buys:

    * an Attempt can record the exact asset id, version and content hash it
      ran, instead of "whatever this module compiled to that day";
    * an operator can override a role body from the config directory without
      a rebuild, and the boot log names any override in effect.

  The composition, the layering and the public functions are unchanged, so
  callers and the roster's `system_prompt:` escape hatch are unaffected.

  The charter carries `{{routine_id}}` and `{{role}}` placeholders. Nothing
  else is substituted, and substitution evaluates nothing.
  """

  alias Custode.Assets

  @doc "Dispatch a role to its composed standing orders (charter + role loop)."
  def for_role(role, routine_id) when is_atom(role) do
    charter(routine_id, role) <> role_orders(role)
  end

  @doc """
  The charter: the invariants every routine agent lives by. Role bodies
  assume all of this and add only their loop.
  """
  def charter(routine_id, role) do
    Assets.render!("charter", %{"routine_id" => routine_id, "role" => role})
  end

  @doc "The asset references behind one role's composed orders (#269)."
  def assets_for_role(role) when is_atom(role) do
    Enum.map(["charter", to_string(role)], &Assets.reference/1)
  end

  defp role_orders(:assistant), do: assistant()
  defp role_orders(:tutor), do: tutor()
  defp role_orders(:caretaker), do: caretaker()
  defp role_orders(:repo_caretaker), do: repo_caretaker()
  defp role_orders(:backlog_worker), do: backlog_worker()
  defp role_orders(:specialist), do: specialist()
  defp role_orders(:star_tracker), do: star_tracker()
  defp role_orders(:contributor_watch), do: contributor_watch()
  defp role_orders(:quake_watch), do: quake_watch()
  defp role_orders(:reviewer), do: reviewer()
  defp role_orders(:steward), do: steward()
  defp role_orders(:consistency_auditor), do: consistency_auditor()

  def assistant, do: Assets.render!("assistant")
  def tutor, do: Assets.render!("tutor")
  def caretaker, do: Assets.render!("caretaker")
  def repo_caretaker, do: Assets.render!("repo_caretaker")
  def backlog_worker, do: Assets.render!("backlog_worker")
  def specialist, do: Assets.render!("specialist")
  def star_tracker, do: Assets.render!("star_tracker")
  def contributor_watch, do: Assets.render!("contributor_watch")
  def quake_watch, do: Assets.render!("quake_watch")
  def reviewer, do: Assets.render!("reviewer")
  def steward, do: Assets.render!("steward")
  def consistency_auditor, do: Assets.render!("consistency_auditor")
  def sub_agent, do: Assets.render!("sub_agent")
  def delegation, do: Assets.render!("delegation")
end
