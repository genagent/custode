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
    case granted(frame, :open_pr, fn -> Custode.Repository.open_pr(repo, params) end) do
      {:ok, pr} -> reply(frame, %{repo: repo, number: pr["number"], url: pr["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.OpenIssue do
  @moduledoc """
  Open an issue on a served repo (#235) -- the "create a backlog" verb, not
  just comment on an existing issue. Policy applies: the title must be
  conventional-commit style. Labels pass through. No shell or git elevation.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:title, :string, required: true, description: "conventional-commit style title")
    field(:body, :string, description: "issue body markdown")
    field(:labels, {:list, :string}, description: "labels to apply")
  end

  @impl true
  def execute(%{repo: repo} = params, frame) do
    case granted(frame, :open_issue, fn -> Custode.Repository.open_issue(repo, params) end) do
      {:ok, issue} -> reply(frame, %{repo: repo, number: issue["number"], url: issue["html_url"]})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.DraftIssues do
  @moduledoc """
  Draft a batch of issues for ONE filing gate (#241). Nothing reaches GitHub
  here: the drafts become rows, you then raise a single request_permission
  naming the batch, and the operator drops any entry it does not want before
  approving. The approved continuation calls `repo_file_drafts`, which files
  exactly what survived. Self-scoped.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  # The identity is optional under either name (#483); `repo` and `issues`
  # stay required by the schema.
  schema do
    field(:routine_id, :string, description: "your own routine id (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")

    embeds_many :issues,
      required: true,
      description: "the drafted issues, in the order you want them filed" do
      field(:title, :string, required: true, description: "conventional-commit style title")
      field(:body, :string, description: "issue body markdown -- the evidence inline")
      field(:labels, {:list, :string}, description: "labels to apply")
    end
  end

  @impl true
  def execute(%{repo: repo, issues: issues} = params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, batch} <- Custode.Drafts.draft(routine_id, repo, issues) do
      reply(frame, %{
        batch_id: batch.batch_id,
        repo: repo,
        drafted:
          for entry <- batch.entries do
            %{id: entry.id, title: entry.title, labels: Custode.Drafts.labels(entry)}
          end,
        next:
          "raise ONE request_permission naming batch #{batch.batch_id} and listing these " <>
            "titles; on approval call repo_file_drafts with the batch id"
      })
    else
      {:error, :empty} -> fail(frame, "no issues to draft")
      {:error, :too_many} -> fail(frame, "at most #{Custode.Drafts.max_entries()} per batch")
      {:error, :missing_title} -> fail(frame, "every drafted issue needs a title")
      {:error, :body_too_large} -> fail(frame, "issue body too large (20KB max)")
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.FileDrafts do
  @moduledoc """
  File the kept entries of a drafted batch (#241) -- the approved
  continuation's verb. Files every entry the operator did not drop, through
  the same policy checks as `repo_open_issue`; a refusal marks that one
  entry and the rest of the batch still files. Self-scoped, and idempotent:
  an already-filed entry is never filed twice.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  # The identity is optional under either name (#483); `batch_id` stays
  # required by the schema.
  schema do
    field(:routine_id, :string, description: "your own routine id (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:batch_id, :string, required: true, description: "the batch id draft_issues returned")
  end

  @impl true
  def execute(%{batch_id: batch_id} = params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         :ok <- check_grant(frame, :file_drafts),
         {:ok, result} <- Custode.Drafts.file(routine_id, batch_id) do
      reply(frame, result)
    else
      {:error, :unknown_batch} -> fail(frame, "no such batch: #{batch_id}")
      {:error, :not_yours} -> fail(frame, "batch #{batch_id} belongs to another routine")
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
    case granted(frame, :comment, fn -> Custode.Repository.comment(repo, number, body) end) do
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
    case granted(frame, :ready_pr, fn -> Custode.Repository.ready_pr(repo, number) end) do
      {:ok, _pr} -> reply(frame, %{repo: repo, number: number, state: "ready_for_review"})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.MergePr do
  @moduledoc """
  Merge a PR on a served repo -- WHERE POLICY ALLOWS. Under the shipped
  policy every repo is merge: :manual, so this refuses with the rule named;
  it exists so the refusal is mechanical rather than remembered. The merge
  method comes from the repository's allowed methods (merge, then squash,
  then rebase), and the reply names the one used.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case granted(frame, :merge_pr, fn -> Custode.Repository.merge_pr(repo, number) end) do
      {:ok, result} ->
        reply(frame, %{
          repo: repo,
          number: number,
          state: "merged",
          merge_method: result["merge_method"]
        })

      {:error, message} ->
        fail(frame, to_string(message))
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
    case granted(frame, :mark_issue, fn ->
           Custode.Repository.mark_issue_ready(repo, number, plan)
         end) do
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
    case granted(frame, :mark_issue, fn ->
           Custode.Repository.mark_issue_blocked(repo, number, reason)
         end) do
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
    case granted(frame, :review_pr, fn ->
           Custode.Repository.review_pr(repo, number, verdict, body)
         end) do
      {:ok, comment} ->
        reply(frame, %{repo: repo, number: number, verdict: verdict, url: comment["html_url"]})

      {:error, message} ->
        fail(frame, to_string(message))
    end
  end
end

# ---------------------------------------------------------------------------
# read verbs (issue #129): scoped GitHub reads, one per gh grant they replace
# ---------------------------------------------------------------------------

defmodule Custode.MCP.RepoTools.ListIssues do
  @moduledoc """
  List a served repo's issues (open by default). Scoped read verb (#129).

  Issues carrying the ignore label are withheld from the survey (#334). The
  operator marks an issue on GitHub, where they are already reading it, and
  the fleet stops spending a sweep re-reading and re-judging it.

  Withheld, not hidden: the reply carries the count and the label, so an
  agent can tell "there is nothing to do" from "there is nothing I am allowed
  to see". A silently shorter list is how a survey starts lying.

  `view_issue` is deliberately unaffected. Ignoring shapes what the fleet
  VOLUNTEERS for, not what it may look at when asked.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:state, :string, description: "open (default), closed, or all")
  end

  @impl true
  def execute(%{repo: repo} = params, frame) do
    case Custode.Repository.list_issues(repo, Map.take(params, [:state])) do
      {:ok, issues} ->
        label = Custode.Repository.ignore_label()
        {kept, ignored} = Custode.Repository.partition_ignored(issues, label)

        reply(frame, %{
          repo: repo,
          issues: kept,
          ignored: length(ignored),
          ignore_label: label
        })

      {:error, message} ->
        fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.ViewIssue do
  @moduledoc "View one issue on a served repo: fields, body, and comments. Scoped read verb (#129)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the issue number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.view_issue(repo, number) do
      {:ok, issue} -> reply(frame, Map.put(issue, :repo, repo))
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.ListPrs do
  @moduledoc "List a served repo's pull requests (open by default). Scoped read verb (#129)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:state, :string, description: "open (default), closed, or all")
  end

  @impl true
  def execute(%{repo: repo} = params, frame) do
    case Custode.Repository.list_prs(repo, Map.take(params, [:state])) do
      {:ok, prs} -> reply(frame, %{repo: repo, prs: prs})
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.ViewPr do
  @moduledoc "View one PR on a served repo: fields and body. Scoped read verb (#129)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.view_pr(repo, number) do
      {:ok, pr} -> reply(frame, Map.put(pr, :repo, repo))
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.PrChecks do
  @moduledoc "The check runs on a PR's head commit. Scoped read verb (#129)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.pr_checks(repo, number) do
      {:ok, result} -> reply(frame, Map.put(result, :repo, repo))
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end

defmodule Custode.MCP.RepoTools.PrDiff do
  @moduledoc "The changed files of a PR, each with its patch. Scoped read verb (#129)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:repo, :string, required: true, description: "owner/name of a SERVED repo")
    field(:number, :integer, required: true, description: "the PR number")
  end

  @impl true
  def execute(%{repo: repo, number: number}, frame) do
    case Custode.Repository.pr_diff(repo, number) do
      {:ok, result} -> reply(frame, Map.put(result, :repo, repo))
      {:error, message} -> fail(frame, to_string(message))
    end
  end
end
