defmodule Custode.Availability.ClaudeOAuthUsage do
  @moduledoc """
  Reads Claude subscription usage without starting a model turn (#524).

  Claude Code owns the OAuth credential. This collector reads its access token
  from the vendor store, presents it once to Anthropic's usage endpoint, and
  retains only the normalized availability snapshot. It never writes, logs or
  returns credential bytes.

  The endpoint is undocumented and optional. Every failure is a small tagged
  value so `Custode.Availability.Probe` can fall back to its sealed turn without
  turning missing usage evidence into a fleet outage.
  """

  alias Custode.Availability.Collectors.Claude

  @usage_url "https://api.anthropic.com/api/oauth/usage"
  @oauth_beta "oauth-2025-04-20"
  @keychain_service "Claude Code-credentials"

  @type credential :: %{
          access_token: String.t(),
          expires_at_ms: number() | nil,
          subscription_type: String.t() | nil
        }

  @doc "Read the local Claude Code credential and collect current plan usage."
  @spec collect(keyword()) :: {:ok, Custode.Availability.Snapshot.t()} | {:error, term()}
  def collect(options \\ []) do
    credential_fun = Keyword.get(options, :credential_fun, &read_credential/1)

    with {:ok, credential} <- credential_fun.(options),
         {:ok, payload} <- fetch_usage(credential.access_token, options) do
      Claude.observe_oauth_usage(
        payload,
        Keyword.put(options, :account_scope, credential.subscription_type)
      )
    end
  rescue
    _error -> {:error, :collector_failed}
  end

  @doc "Read one OAuth credential from Claude Code's vendor-owned store."
  @spec read_credential(keyword()) :: {:ok, credential()} | {:error, term()}
  def read_credential(options \\ []) do
    config_dir = config_dir(options)

    if darwin?(Keyword.get(options, :platform, :os.type())) do
      case read_keychain(config_dir, options) do
        {:ok, credential} -> {:ok, credential}
        {:error, keychain_reason} -> file_after_keychain(config_dir, keychain_reason, options)
      end
    else
      read_file(config_dir, options)
    end
  end

  @doc false
  @spec parse_credential(binary()) :: {:ok, credential()} | {:error, :invalid_credentials}
  def parse_credential(raw) when is_binary(raw) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(String.trim(raw)),
         body when is_map(body) <- Map.get(decoded, "claudeAiOauth", decoded),
         token when is_binary(token) and token != "" <- Map.get(body, "accessToken") do
      {:ok,
       %{
         access_token: token,
         expires_at_ms: number_or_nil(Map.get(body, "expiresAt")),
         subscription_type: string_or_nil(Map.get(body, "subscriptionType"))
       }}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  @doc false
  @spec keychain_service(Path.t()) :: String.t()
  def keychain_service(config_dir) do
    digest = :crypto.hash(:sha256, Path.expand(config_dir)) |> Base.encode16(case: :lower)
    @keychain_service <> "-" <> binary_part(digest, 0, 8)
  end

  defp fetch_usage(access_token, options) do
    http_fun = Keyword.get(options, :http_fun, &Req.get/2)

    request_options = [
      headers: [
        {"authorization", "Bearer " <> access_token},
        {"anthropic-beta", @oauth_beta},
        {"accept", "application/json"}
      ],
      retry: false,
      receive_timeout: 10_000
    ]

    case http_fun.(@usage_url, request_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :credential_rejected}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  rescue
    _error -> {:error, :request_failed}
  end

  defp read_keychain(config_dir, options) do
    command_fun = Keyword.get(options, :command_fun, &System.cmd/3)
    user = Keyword.get(options, :user, System.get_env("USER"))

    config_dir
    |> keychain_services()
    |> Enum.reduce_while({:error, :credential_not_found}, fn service, previous ->
      case read_keychain_service(service, user, command_fun) do
        {:ok, credential} -> {:halt, {:ok, credential}}
        {:error, :credential_not_found} -> {:cont, previous}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp read_keychain_service(service, user, command_fun) do
    args =
      ["find-generic-password", "-s", service] ++
        if(is_binary(user) and user != "", do: ["-a", user], else: []) ++ ["-w"]

    case command_fun.("security", args, stderr_to_stdout: true) do
      {raw, 0} -> parse_credential(raw)
      {_output, _status} -> {:error, :credential_not_found}
    end
  rescue
    _error -> {:error, :credential_not_found}
  end

  defp keychain_services(config_dir) do
    hashed = keychain_service(config_dir)

    if Path.expand(config_dir) == default_config_dir() do
      [@keychain_service, hashed]
    else
      [hashed]
    end
  end

  defp file_after_keychain(config_dir, keychain_reason, options) do
    case read_file(config_dir, options) do
      {:error, :credential_not_found} -> {:error, keychain_reason}
      result -> result
    end
  end

  defp read_file(config_dir, options) do
    read_fun = Keyword.get(options, :read_fun, &File.read/1)

    case read_fun.(Path.join(config_dir, ".credentials.json")) do
      {:ok, raw} -> parse_credential(raw)
      {:error, reason} when reason in [:enoent, :enotdir] -> {:error, :credential_not_found}
      {:error, _reason} -> {:error, :credential_unreadable}
    end
  rescue
    _error -> {:error, :credential_unreadable}
  end

  defp config_dir(options) do
    case Keyword.get(options, :config_dir, System.get_env("CLAUDE_CONFIG_DIR")) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _unset -> default_config_dir()
    end
  end

  defp default_config_dir, do: Path.join(System.user_home!(), ".claude") |> Path.expand()

  defp darwin?(:darwin), do: true
  defp darwin?({:unix, :darwin}), do: true
  defp darwin?(_platform), do: false

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
