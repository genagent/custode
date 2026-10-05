defmodule Custode.Workflow.ExecutionPolicy do
  @moduledoc "Opt-in host execution policy; native conformance and physical settlement remain unknown."
  alias Custode.Workflow.{ResultContract, Results}

  @profile "custode.workflow_tool_free.v1"
  @dynamic ~w(model effort working_dir json_schema max_budget_usd timeout)a
  @allowed_args Enum.map(@dynamic, &Atom.to_string/1) ++
                  ~w(prompt max_turns hermetic setting_sources strict_mcp_config mcp_config no_session_persistence permission_mode)
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
    no_session_persistence: true,
    max_turns: 1,
    system_prompt:
      "Analyse only the supplied workflow input. No tools. Return the requested structured output."
  ]
  @stored ObanClaude.Args.defaults(
            mcp_config: [],
            strict_mcp_config: true,
            hermetic: :full,
            setting_sources: "",
            permission_mode: :plan,
            no_session_persistence: true,
            max_turns: 1
          )

  def profile, do: @profile
  def selected?(%{definition_snapshot: %{"execution_profile" => @profile}}), do: true
  def selected?(_run), do: false
  def admit_args(args), do: Map.merge(args, @stored)

  def bind(contract, run, args) do
    if selected?(run), do: Map.put(contract, "execution_policy", capture(args)), else: contract
  end

  def check(run, job) do
    case run.definition_snapshot && run.definition_snapshot["execution_profile"] do
      nil ->
        if get_in(job.meta, ["result_contract", "execution_policy"]),
          do: {:error, :unexpected_execution_policy},
          else: :ok

      @profile ->
        if valid_args?(job.args) and valid_context?(run.context, job.args) and
             get_in(job.meta, ["result_contract", "execution_policy"]) == capture(job.args),
           do: :ok,
           else: {:error, :execution_policy_changed_or_missing}

      _unknown ->
        {:error, :unknown_execution_profile}
    end
  end

  # Unknown query options are omitted, rather than merely overriding known unsafe ones.
  # A new wrapper option cannot silently widen this versioned profile.
  def query(prompt, opts), do: ClaudeWrapper.query(prompt, sealed_opts(opts))
  def sealed_opts(opts), do: opts |> Keyword.take(@dynamic) |> Keyword.merge(@policy)

  defp capture(args) do
    dynamic =
      for key <- @dynamic, Map.has_key?(args, Atom.to_string(key)) do
        value = args[Atom.to_string(key)]
        {key, if(key == :effort, do: effort(value), else: value)}
      end

    %{
      "profile" => @profile,
      "basis" => "host_pinned_wrapper_options_not_native_conformance",
      "effective_query_options" => Jason.decode!(Jason.encode!(Map.new(sealed_opts(dynamic)))),
      "effective_query_sha256" => Results.args_hash(sealed_opts(dynamic)),
      "packages" =>
        Map.new([:oban_claude, :claude_wrapper, :forcola], fn package ->
          {Atom.to_string(package), to_string(Application.spec(package, :vsn))}
        end),
      "native_conformance" => "unverified",
      "physical_settlement" => "unattested"
    }
  end

  defp valid_args?(args) do
    Map.take(args, Map.keys(@stored)) == @stored and
      Enum.all?(Map.keys(args), &(&1 in @allowed_args)) and valid_limits?(args)
  end

  defp valid_context?(%{"working_dir" => directory} = context, args) when is_binary(directory) do
    args["max_budget_usd"] == context["max_budget_usd"] and
      args["working_dir"] == Path.expand(directory) and
      context["result_contract_version"] == ResultContract.version()
  end

  defp valid_context?(_context, _args), do: false

  defp valid_limits?(%{"max_budget_usd" => budget, "timeout" => timeout}),
    do: is_number(budget) and budget > 0 and timeout == 900_000

  defp valid_limits?(_args), do: false

  defp effort(value) do
    Map.get(
      %{"low" => :low, "medium" => :medium, "high" => :high, "xhigh" => :xhigh, "max" => :max},
      value,
      value
    )
  end
end
