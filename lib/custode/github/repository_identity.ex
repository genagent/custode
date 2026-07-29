defmodule Custode.GitHub.RepositoryIdentityBehaviour do
  @moduledoc "Resolves a mutable owner/name reference to stable GitHub repository identity."

  @callback resolve(String.t()) ::
              {:ok, %{id: String.t(), name_with_owner: String.t()}} | {:error, term()}
end

defmodule Custode.GitHub.RepositoryIdentity do
  @moduledoc """
  Resolves repository identity through GitHub's REST representation.

  GitHub follows repository rename redirects for this endpoint, so callers get
  both the stable numeric ID and the current owner/name projection.
  """

  @behaviour Custode.GitHub.RepositoryIdentityBehaviour

  @impl true
  def resolve(owner_name) when is_binary(owner_name) do
    with [owner, name] <- String.split(owner_name, "/", parts: 2),
         {:ok, token} <- token(),
         client = GhEx.new(auth: {:token, token}),
         {:ok, repository, _meta} <- GhEx.Repositories.get(client, owner, name),
         id when is_integer(id) <- repository["id"],
         full_name when is_binary(full_name) <- repository["full_name"] do
      {:ok, %{id: Integer.to_string(id), name_with_owner: full_name}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_repository_identity, owner_name, other}}
    end
  end

  defp token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _unset -> cli_token()
    end
  end

  defp cli_token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        with {out, 0} <- System.cmd("gh", ["auth", "token"], stderr_to_stdout: true),
             token when token != "" <- String.trim(out) do
          :persistent_term.put({__MODULE__, :token}, token)
          {:ok, token}
        else
          _failure -> {:error, :no_github_token}
        end

      token ->
        {:ok, token}
    end
  end
end
