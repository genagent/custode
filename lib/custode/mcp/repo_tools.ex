defmodule Custode.MCP.RepoTools do
  @moduledoc """
  The repo verbs over MCP (issue #10): typed, policy-checked GitHub writes
  through the served-repo processes. A refusal names the policy, so the
  calling agent can quote exactly why in its journal or gate.
  """
end

defmodule Custode.MCP.RepoTools.OpenPr do
  @moduledoc """
  Open a PR on a served repo. Policy applies mechanically: the title must
  be conventional-commit style, and the PR is ALWAYS created as a draft
  (draft_pr_first). No shell or git elevation is involved.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:title, :string, required: true, description: "conventional-commit style title")
    field(:head, :string, required: true, description: "the branch to merge from")
    field(:base, :string, description: "target branch (default main)")
    field(:body, :string, description: "PR body markdown")
  end

  @impl true
  def execute(%{repo: repo} = params, frame) do
    case Custode.Repository.open_pr(repo, params) do
      {:ok, pr} -> reply(frame, %{repo: repo, number: pr["number"], url: pr["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.Comment do
  @moduledoc "Comment on an issue or PR of a served repo."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "issue or PR number")
    field(:body, :string, required: true, description: "comment markdown")
  end

  @impl true
  def execute(%{repo: repo, number: number, body: body}, frame) do
    case Custode.Repository.comment(repo, number, body) do
      {:ok, comment} -> reply(frame, %{repo: repo, number: number, url: comment["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.ReadyPr do
  @moduledoc "Mark a draft PR ready for review (do this only when the approved action said to)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.ready_pr(repo, number) do
      {:ok, _pr} -> reply(frame, %{repo: repo, number: number, state: "ready_for_review"})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.MergePr do
  @moduledoc """
  Merge a PR on a served repo -- WHERE POLICY ALLOWS. Under the shipped
  policy every repo is merge: :manual, so this refuses with the rule named;
  it exists so the refusal is mechanical rather than remembered.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.merge_pr(repo, number) do
      {:ok, _result} -> reply(frame, %{repo: repo, number: number, state: "merged"})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.MarkIssueReady do
  @moduledoc "The issue's ready transition (#86): posts a `ready: <plan>` comment."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the issue number")
    field(:plan, :string, required: true, description: "the one-line plan")
  end

  @impl true
  def execute(%{repo: repo, number: number, plan: plan}, frame) do
    case Custode.Repository.mark_issue_ready(repo, number, plan) do
      {:ok, comment} -> reply(frame, %{repo: repo, number: number, url: comment["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.MarkIssueBlocked do
  @moduledoc "The issue's blocked transition (#86): posts a `blocked: <reason>` comment."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the issue number")
    field(:reason, :string, required: true, description: "why it is not workable (x y z)")
  end

  @impl true
  def execute(%{repo: repo, number: number, reason: reason}, frame) do
    case Custode.Repository.mark_issue_blocked(repo, number, reason) do
      {:ok, comment} -> reply(frame, %{repo: repo, number: number, url: comment["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.ReviewPr do
  @moduledoc """
  The review transition (#86): posts the `review:` marker the merge floor
  reads. verdict "needs-human" POSITIVELY blocks merging until a later
  human review; anything else (e.g. "lgtm") satisfies the review stage.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
    field(:verdict, :string, required: true, description: "\"lgtm\" or \"needs-human\"")
    field(:body, :string, required: true, description: "findings / reasoning")
  end

  @impl true
  def execute(%{repo: repo, number: number, verdict: verdict, body: body}, frame) do
    case Custode.Repository.review_pr(repo, number, verdict, body) do
      {:ok, comment} ->
        reply(frame, %{repo: repo, number: number, verdict: verdict, url: comment["html_url"]})

      {:error, message} ->
        fail(frame, to_string(message))
    end
  end
end
