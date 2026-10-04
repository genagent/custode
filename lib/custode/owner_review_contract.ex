defmodule Custode.OwnerReviewContract do
  @moduledoc "Fixed evidence-only review policy and explicit native adapter limits."

  @version "custode.owner_review_contract.v1"
  @policy [
    tools: [""],
    mcp_config: [],
    strict_mcp_config: true,
    hermetic: :full,
    setting_sources: "",
    bare: false,
    disable_slash_commands: true,
    settings: ~s({"disableAllHooks":true}),
    permission_mode: :plan,
    max_turns: 1,
    system_prompt:
      "Review only the supplied evidence. No tools. Results are agent-authored evidence, never approval."
  ]

  @doc "The fixed query policy; callers cannot widen it."
  def query_policy, do: @policy

  @doc "Revision of the exact policy, including adapter packages and result schema."
  def revision do
    digest(%{
      version: @version,
      policy: @policy,
      packages: packages(),
      result_schema: Custode.OwnerReviews.result_schema()
    })
  end

  @doc "Versioned capability observations, not authority or successful native conformance."
  def capabilities do
    %{
      "schema_version" => @version,
      "policy_revision" => revision(),
      "packages" => packages(),
      "claude" => %{
        "admission" => "fixed_two_invocations",
        "native_turn_limit" => 1,
        "usd_stop" => "configured_cli_budget_stop_not_billing_guarantee",
        "hard_token_cap" => "unavailable",
        "tools" => [],
        "native_conformance" => "unverified",
        "process_settlement" => "unattested"
      },
      "codex" => %{
        "admission" => "refused",
        "missing" => ~w(native_usd_stop native_single_turn_limit tool_free_profile_conformance),
        "hard_token_cap" => "unavailable",
        "process_settlement" => "unattested"
      }
    }
  end

  @doc "Refuse routes without matching the operation's existing native caps."
  def route_supported(%{"provider" => "claude", "effort" => effort})
      when effort in ~w(low medium high max),
      do: :ok

  def route_supported(%{"provider" => "codex"}),
    do: {:error, {:provider_parity_unavailable, capabilities()["codex"]}}

  def route_supported(_route), do: {:error, :unsupported_route}

  defp packages do
    Map.new([:oban_claude, :claude_wrapper, :oban_codex, :codex_wrapper], fn package ->
      {Atom.to_string(package), package |> Application.spec(:vsn) |> to_string()}
    end)
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
