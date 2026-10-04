defmodule Custode.IntegrationCatalog do
  @moduledoc "Versioned external read integrations and immutable per-admission native configurations."
  alias Custode.{AgentHandoff, Feed, Repo}
  alias Custode.Operator.Authority

  @audiences ~w(routine sub_agent one_shot workflow)
  @reserved ~w(custode memory)

  defmodule Override do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:name, :string, autogenerate: false}
    schema "integration_overrides" do
      field(:settings, :map)
    end
  end

  defmodule Request do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:request_id, :string, autogenerate: false}
    schema "integration_requests" do
      field(:fingerprint, :string)
      field(:result, :map)
    end
  end

  @doc "Configured catalog with durable access overrides, without resolving credentials."
  def definitions do
    overrides = Repo.all(Override) |> Map.new(&{&1.name, &1.settings})
    raw = Application.get_env(:custode, :external_mcp_servers, [])
    names = Enum.map(raw, & &1.name)
    duplicate = names -- Enum.uniq(names)

    Enum.map(raw, fn server ->
      entry = normalize(server, Map.get(overrides, server.name, %{}))

      entry =
        if server.name in duplicate, do: Map.put(entry, :reason, "duplicate_name"), else: entry

      Map.put(entry, :revision, digest(entry))
    end)
  end

  @doc "Inspect caller-filtered effective catalog facts. No endpoint probe or model runs."
  def inspect_for(actor, provider \\ "claude") do
    with {:ok, context} <- context(actor, provider) do
      entries = Enum.map(definitions(), &projection(&1, context))

      {:ok,
       %{
         schema_version: "custode.integration_catalog.v1",
         revision: digest(entries),
         observed_at: DateTime.to_iso8601(DateTime.utc_now()),
         entries: entries,
         availability: "not_probed",
         authentication: "not_probed",
         invocation_evidence: "none",
         native_revocation: "existing_connections_may_survive_disable"
       }}
    end
  end

  @doc "Human-only, idempotent, revision-checked enable/deny access update for an existing integration."
  def update_access(actor, name, expected_revision, request_id, settings) do
    with :ok <- Authority.human(actor),
         :ok <- valid_update(name, expected_revision, request_id, settings) do
      fingerprint = digest({actor, name, expected_revision, settings})

      result =
        Repo.transaction(
          fn -> update_access!(name, expected_revision, request_id, settings, fingerprint) end,
          mode: :immediate
        )

      publish_update(result)
    end
  end

  defp publish_update({:ok, {result, event}}) do
    if event, do: Feed.publish_committed(event)
    {:ok, result}
  end

  defp publish_update({:error, reason}), do: {:error, reason}

  @doc "Capture exact eligible entries into a unique native configuration for one admission."
  def capture(%{provider: provider} = context, opts \\ []) when provider in ["claude", "codex"] do
    entries = definitions()
    eligible = Enum.filter(entries, &(reason(&1, context) == nil))
    materialized = Enum.map(eligible, &resolve_credential/1)
    allowed = Enum.filter(materialized, &(elem(&1, 1) != :missing))

    revision =
      digest(
        {entries, context,
         Enum.map(materialized, fn {entry, token} ->
           {entry.name, if(token == :missing, do: :missing, else: digest(token))}
         end)}
      )

    servers =
      Map.new(allowed, fn {entry, credential} ->
        {entry.name, native_server(entry, credential)}
      end)

    %{
      revision: revision,
      entries: capture_projections(entries, materialized, context),
      credential_binding:
        if(provider == "claude", do: "captured_private_file", else: "environment_at_launch"),
      config_path:
        if(provider == "claude" and map_size(servers) > 0,
          do: config_file(revision, servers, Keyword.get(opts, :materialize, true))
        ),
      allowed_tools:
        Enum.flat_map(allowed, fn {entry, _token} ->
          Enum.map(entry.tools, &("mcp__#{entry.name}__" <> &1))
        end),
      codex_overrides:
        if(provider == "codex", do: Enum.flat_map(allowed, &codex_overrides/1), else: [])
    }
  end

  @doc "Append captured catalog configuration to Claude args, keeping the caller's existing tool contract."
  def apply_claude(args, context, opts \\ []) when is_map(args) do
    context =
      Map.merge(context, %{
        provider: "claude",
        unsafe_permissions: args["permission_mode"] == "bypass_permissions"
      })

    captured = capture(context, opts)

    args =
      if captured.config_path do
        args
        |> Map.update("mcp_config", [captured.config_path], &(&1 ++ [captured.config_path]))
        |> Map.update(
          "allowed_tools",
          captured.allowed_tools,
          &Enum.uniq(&1 ++ captured.allowed_tools)
        )
      else
        args
      end

    args = args |> Map.put("strict_mcp_config", true) |> Map.put_new("mcp_config", [])

    Map.put(args, "custode_integration_capture", %{
      revision: captured.revision,
      entries: captured.entries,
      credential_binding: captured.credential_binding
    })
  end

  defp capture_projections(entries, materialized, context) do
    missing = for {entry, :missing} <- materialized, do: entry.name

    Enum.map(entries, fn entry ->
      facts = projection(entry, context)

      if entry.name in missing,
        do: %{facts | disposition: "credential_unavailable", allowed_tools: []},
        else: facts
    end)
  end

  defp update_access!(name, expected, key, settings, fingerprint) do
    case Repo.get(Request, key) do
      %Request{fingerprint: ^fingerprint, result: result} ->
        {result, nil}

      %Request{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        current =
          Enum.find(definitions(), &(&1.name == name)) || Repo.rollback(:unknown_integration)

        if current.revision != expected, do: Repo.rollback(:revision_conflict)

        existing =
          case Repo.get(Override, name) do
            nil -> %{}
            row -> row.settings
          end

        Repo.insert!(%Override{name: name, settings: Map.merge(existing, settings)},
          on_conflict: {:replace, [:settings]},
          conflict_target: :name
        )

        updated = Enum.find(definitions(), &(&1.name == name))
        result = %{name: name, revision: updated.revision, enabled: updated.enabled}
        Repo.insert!(%Request{request_id: key, fingerprint: fingerprint, result: result})

        {:ok, event} =
          Feed.record_in_transaction(%{
            event: "integration_access_updated",
            summary: "integration #{name} access revision #{updated.revision}",
            agent: "operator"
          })

        {result, event}
    end
  end

  defp valid_update(name, revision, key, settings) do
    if valid_identity?(name, revision, key) and valid_settings?(settings),
      do: :ok,
      else: {:error, :invalid_access_update}
  end

  defp valid_identity?(name, revision, key),
    do:
      is_binary(name) and is_binary(revision) and revision != "" and
        is_binary(key) and byte_size(key) in 1..200

  defp valid_settings?(settings) when is_map(settings) and map_size(settings) in 1..2 do
    Enum.all?(settings, fn
      {"enabled", value} -> is_boolean(value)
      {"denied_agents", value} -> string_list?(value)
      _other -> false
    end)
  end

  defp valid_settings?(_settings), do: false

  defp normalize(server, override) do
    name = server.name
    allowed = Map.get(server, :allowed, [])
    prefix = "mcp__#{name}__"

    tools =
      if string_list?(allowed),
        do: Enum.map(allowed, &String.replace_prefix(&1, prefix, "")),
        else: []

    entry = %{
      name: name,
      type: to_string(Map.get(server, :type, :http)),
      url: server[:url],
      command: server[:command],
      args: Map.get(server, :args, []),
      tools: tools,
      enabled: Map.get(override, "enabled", Map.get(server, :enabled, true)),
      denied_agents: Map.get(override, "denied_agents", Map.get(server, :denied_agents, [])),
      audiences: Map.get(server, :audiences, @audiences),
      read_only: Map.get(server, :read_only, false),
      credential_ref: server[:credential_ref],
      reason: nil
    }

    %{entry | reason: definition_problem(entry, allowed, prefix)}
  end

  defp definition_problem(entry, allowed, prefix) do
    checks = [
      {valid_name?(entry.name), "invalid_or_reserved_name"},
      {exact_tools?(allowed, prefix), "exact_tool_allowlist_required"},
      {Enum.all?(entry.tools, &Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, &1)), "invalid_tool_name"},
      {entry.type in ~w(http sse stdio), "unsupported_transport"},
      {endpoint_valid?(entry), "invalid_endpoint_or_launch"},
      {entry.read_only == true, "read_only_declaration_required"},
      {valid_audience?(entry.audiences), "invalid_audience"},
      {string_list?(entry.denied_agents), "invalid_access"},
      {credential_ref?(entry.credential_ref), "invalid_credential_reference"},
      {entry.type != "stdio" or is_nil(entry.credential_ref), "stdio_credential_unsupported"}
    ]

    Enum.find_value(checks, fn {valid, message} -> if not valid, do: message end)
  end

  defp valid_name?(name), do: Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, name) and name not in @reserved

  defp exact_tools?(allowed, prefix),
    do:
      string_list?(allowed) and allowed != [] and
        Enum.all?(allowed, &String.starts_with?(&1, prefix))

  defp valid_audience?(audiences),
    do: string_list?(audiences) and Enum.all?(audiences, &(&1 in @audiences))

  defp endpoint_valid?(%{type: "stdio", command: command, args: args}),
    do: is_binary(command) and command != "" and string_list?(args)

  defp endpoint_valid?(%{url: url}) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil and
      uri.query == nil and uri.fragment == nil
  end

  defp endpoint_valid?(_entry), do: false
  defp credential_ref?(nil), do: true

  defp credential_ref?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Z][A-Z0-9_]*\z/, value)

  defp credential_ref?(_value), do: false

  defp string_list?(value),
    do:
      is_list(value) and length(value) <= 100 and
        Enum.all?(value, &(is_binary(&1) and byte_size(&1) in 1..200))

  defp reason(entry, context) do
    cond do
      entry.reason -> entry.reason
      not entry.enabled -> "disabled"
      context.agent_id in entry.denied_agents -> "worker_denied"
      context.audience not in entry.audiences -> "audience_denied"
      context.provider == "codex" and entry.type == "sse" -> "codex_sse_unsupported"
      Map.get(context, :unsafe_permissions, false) -> "bypass_permissions_not_supported"
      true -> nil
    end
  end

  defp projection(entry, context) do
    denied = reason(entry, context)

    entry
    |> Map.take([:name, :revision, :enabled, :credential_ref])
    |> Map.put(:disposition, denied || "configured")
    |> Map.put(:allowed_tools, if(denied, do: [], else: entry.tools))
    |> Map.put(:transport, if(denied, do: nil, else: entry.type))
    |> Map.put(:endpoint, if(denied, do: nil, else: entry.url))
    |> Map.put(
      :launch,
      if(not is_nil(denied) or entry.type != "stdio",
        do: nil,
        else: %{command: entry.command, args: entry.args}
      )
    )
    |> Map.put(:advertised, %{
      tools: "not_observed",
      prompts: "not_observed",
      resources: "not_observed"
    })
    |> Map.put(:client_context_support, "not_verified")
  end

  defp context(%{kind: :operator, id: id}, provider)
       when is_binary(id) and id != "" and provider in ["claude", "codex"],
       do: {:ok, %{agent_id: id, audience: "routine", provider: provider}}

  defp context(%{kind: :routine, id: id}, provider) when provider in ["claude", "codex"] do
    with {:ok, _routine} <- AgentHandoff.authorization_routine(id),
         do: {:ok, %{agent_id: id, audience: "routine", provider: provider}}
  end

  defp context(%{kind: :sub_agent, id: id}, provider)
       when is_binary(id) and id != "" and provider in ["claude", "codex"],
       do: {:ok, %{agent_id: id, audience: "sub_agent", provider: provider}}

  defp context(_actor, _provider), do: {:error, :unauthenticated_or_unsupported_provider}

  defp resolve_credential(%{credential_ref: nil} = entry), do: {entry, nil}
  defp resolve_credential(entry), do: {entry, System.get_env(entry.credential_ref) || :missing}

  defp native_server(%{type: "stdio"} = entry, _credential),
    do: %{"type" => "stdio", "command" => entry.command, "args" => entry.args}

  defp native_server(entry, credential) do
    server = %{"type" => entry.type, "url" => entry.url}

    if credential,
      do: Map.put(server, "headers", %{"Authorization" => "Bearer " <> credential}),
      else: server
  end

  defp codex_overrides({entry, credential}) do
    root = "mcp_servers." <> entry.name

    launch =
      case entry.type do
        "http" ->
          [override(root <> ".url", entry.url)]

        "stdio" ->
          [override(root <> ".command", entry.command), override(root <> ".args", entry.args)]
      end

    auth =
      if credential,
        do: [override(root <> ".bearer_token_env_var", entry.credential_ref)],
        else: []

    launch ++
      auth ++
      [
        override(root <> ".enabled_tools", entry.tools),
        override(root <> ".default_tools_approval_mode", "approve"),
        root <> ".required=true"
      ]
  end

  defp override(key, value), do: key <> "=" <> Jason.encode!(value)

  defp config_file(revision, servers, materialize?) do
    directory = Path.join(Path.dirname(Custode.MCP.config_path()), "integration_captures")
    path = Path.join(directory, revision <> ".json")

    if materialize?,
      do: write_capture!(directory, path, Jason.encode!(%{"mcpServers" => servers}))

    path
  end

  defp write_capture!(directory, path, encoded) do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    temporary = Path.join(directory, Ecto.UUID.generate() <> ".tmp")

    try do
      File.write!(temporary, "", [:exclusive])
      File.chmod!(temporary, 0o600)
      File.write!(temporary, encoded)
      publish_capture!(temporary, path, encoded)
    after
      File.rm(temporary)
    end
  end

  defp publish_capture!(temporary, path, encoded) do
    case File.ln(temporary, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if File.read!(path) != encoded, do: raise("captured integration configuration changed")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "capture configuration", path: path
    end
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
