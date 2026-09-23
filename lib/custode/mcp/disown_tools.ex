defmodule Custode.MCP.DisownTools do
  @moduledoc """
  Declaring a pull request is not yours (#313), and taking it back.

  Worker-tier, because the judgment belongs to the agent that looked at the
  diff. What the operator gets is the CONSEQUENCE: a red check on a disowned
  PR stops being the fleet's problem and becomes theirs.
  """
end

defmodule Custode.MCP.DisownTools.DisownPr do
  @moduledoc """
  Declare that a pull request in your repository is not your work.

  Use this when you have looked at a PR, concluded it is somebody else's (the
  operator's own branch, a bot's release PR, a dependency update), and will
  not be fixing it. Say WHY: the reason is the record of the judgment.

  The consequence is not cosmetic. A red check on a PR you own is the fleet's
  problem and stays out of the operator's way, because your next beat will
  look at it. A red check on a PR you have disowned is nobody's problem until
  the operator makes it theirs, so it is raised to them.

  Do not use this to avoid work you could do. Disowning your own failing PR
  hides it from you and hands it to a human.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.{Disowned, MCP.Scope}

  schema do
    field(:repo, :string, required: true, description: ~s(the repo, as "owner/name"))
    field(:number, :integer, required: true, description: "the pull request number")

    field(:reason, :string,
      description: "why it is not yours, in one line -- kept as the record of the judgment"
    )
  end

  @impl true
  def execute(params, frame) do
    caller = Custode.MCP.caller(frame)

    with :ok <- Scope.authorize_repo_fact(frame, params.repo),
         :ok <- authorize_existing(frame, params.repo, params.number),
         {:ok, row} <-
           Disowned.disown(caller.id, params.repo, params.number, params[:reason]) do
      reply(frame, %{
        repo: row.repo,
        number: row.number,
        disowned_by: row.agent_id,
        reason: row.reason,
        note: "a red check here now reaches the operator instead of waiting on you"
      })
    else
      {:error, reason} -> fail(frame, to_string(reason))
    end
  end

  defp authorize_existing(frame, repo, number) do
    case Disowned.get(repo, number) do
      nil -> :ok
      row -> Scope.authorize_owner(frame, row.agent_id)
    end
  end
end

defmodule Custode.MCP.DisownTools.ReclaimPr do
  @moduledoc """
  Take back a pull request you previously disowned: it is your work after all.

  A disownment is a judgment, and judgments are revisable. Reclaiming returns
  a red check on that PR to the fleet, so it stops being raised to the
  operator and goes back to being something your next beat looks at.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.{Disowned, MCP.Scope}

  schema do
    field(:repo, :string, required: true, description: ~s(the repo, as "owner/name"))
    field(:number, :integer, required: true, description: "the pull request number")
  end

  @impl true
  def execute(params, frame) do
    with :ok <- Scope.authorize_repo_fact(frame, params.repo),
         {:ok, row} <- fetch_record(params.repo, params.number),
         :ok <- Scope.authorize_owner(frame, row.agent_id),
         :ok <- Disowned.reclaim(row) do
      reply(frame, %{repo: params.repo, number: params.number, disowned: false})
    else
      {:error, :not_disowned} ->
        fail(frame, "#{params.repo}##{params.number} was not disowned")

      {:error, reason} ->
        fail(frame, to_string(reason))
    end
  end

  defp fetch_record(repo, number) do
    case Disowned.get(repo, number) do
      nil -> {:error, :not_disowned}
      row -> {:ok, row}
    end
  end
end

defmodule Custode.MCP.DisownTools.ListDisowned do
  @moduledoc """
  Pull requests the fleet has declared are not its work, newest first.

  The durable answer to "what is red that nobody is going to fix?", which is
  a different question from `list_gates` ("what is blocked on me?") and from
  `list_asks` ("what am I being asked?").
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, description: "restrict to one repo")
  end

  @impl true
  def execute(params, frame) do
    disowned =
      Custode.Disowned.all()
      |> filter_repo(params[:repo])
      |> Enum.map(
        &%{
          repo: &1.repo,
          number: &1.number,
          disowned_by: &1.agent_id,
          reason: &1.reason,
          at: &1.inserted_at
        }
      )

    reply(frame, %{disowned: disowned})
  end

  defp filter_repo(rows, nil), do: rows
  defp filter_repo(rows, repo), do: Enum.filter(rows, &(&1.repo == repo))
end
