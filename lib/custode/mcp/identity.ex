defmodule Custode.MCP.Identity do
  @moduledoc """
  Caller identity for the MCP surface (#1 + #2): every caller carries a
  bearer token, tokens map to identities, and the router refuses requests
  without one -- so by the time a tool runs, `frame.assigns` says WHO is
  calling, verified, not claimed.

  Identities are minted fresh each boot (agents' configs are rewritten at
  boot anyway, and sub-agents do not survive restarts): one per routine,
  one per spawned sub-agent, and one OPERATOR token written to a 0600
  file for the CLI and the human. Losing state on restart is the point --
  tokens have the same lifetime as the processes they identify.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Mint (or re-mint) a token for an identity; returns the token."
  def mint(kind, id) when kind in [:operator, :routine, :sub_agent] do
    GenServer.call(__MODULE__, {:mint, kind, id})
  end

  @doc "Resolve a bearer token: `{:ok, %{kind: kind, id: id}}` | `:error`."
  def verify(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, identity}] -> {:ok, identity}
      [] -> :error
    end
  end

  def verify(_token), do: :error

  @doc "Return the live token for an identity, or `:error` when none was minted."
  def token(kind, id) when kind in [:operator, :routine, :sub_agent] do
    case :ets.match(@table, {:"$1", %{kind: kind, id: id}}) do
      [[token]] -> {:ok, token}
      [] -> :error
    end
  end

  @doc "The operator token file path (0600, rewritten each boot)."
  def operator_token_path do
    Path.expand(
      Path.join(Application.get_env(:custode, :mcp_config_dir, "tmp"), "operator.token")
    )
  end

  @doc "Read the operator token (env override first, then the boot file)."
  def operator_token do
    case System.get_env("CUSTODE_OPERATOR_TOKEN") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _unset -> read_token_file()
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])

    operator = do_mint(:operator, "operator")
    File.mkdir_p!(Path.dirname(operator_token_path()))
    File.write!(operator_token_path(), operator)
    File.chmod!(operator_token_path(), 0o600)

    # This process owns the in-memory credential table. A one-for-one restart
    # therefore revokes every old routine token even though BootConfigWriter
    # does not restart with it. Reprovision the configured routines here and
    # rewrite their files with those exact tokens before accepting requests.
    # Use do_mint/2 directly: calling the public GenServer API from init/1
    # would deadlock on this process.
    routines = Custode.Routine.all()

    for routine <- routines do
      token = do_mint(:routine, routine.id)
      :ok = Custode.MCP.write_routine_config!(routine.id, token)
    end

    # On initial boot the handoff coordinator has not started yet and will
    # reconcile the roster as its own boot fence. On an isolated Identity
    # restart it is already live, so tell it that every Codex execution
    # contract carrying one of the revoked tokens may now be stale.
    if Process.whereis(Custode.AgentHandoff) do
      for routine <- routines do
        :ok = Custode.AgentHandoff.reconcile(routine.id)
      end
    end

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:mint, kind, id}, _from, state) do
    {:reply, do_mint(kind, id), state}
  end

  defp do_mint(kind, id) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    # one live token per identity: re-minting revokes the old one
    :ets.match_delete(@table, {:_, %{kind: kind, id: id}})
    :ets.insert(@table, {token, %{kind: kind, id: id}})
    token
  end

  defp read_token_file do
    case File.read(operator_token_path()) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, reason} -> {:error, reason}
    end
  end
end
