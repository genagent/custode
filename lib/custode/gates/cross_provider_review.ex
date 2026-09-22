defmodule Custode.Gates.CrossProviderReview do
  @moduledoc """
  Sealed review evidence for `ready_pr` and `merge` gates.

  The job snapshots repository evidence into files and gives their paths to
  the provider family opposite the gate's author. A review is keyed by pull
  request head, so an unchanged head reuses the first result. Review rounds
  are capped per pull request and never decide the gate.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Gates
  alias Custode.Gates.Gate
  alias Custode.Gates.Review
  alias Custode.Repo

  @eligible_classes ~w(ready_pr merge)
  @severities ~w(BLOCK FIX_FIRST WARN NIT OUT_OF_SCOPE INSUFFICIENT_EVIDENCE NEEDS_HUMAN)
  @evidence_files ~w(intent.md gate.json checks.json diff.patch)

  @doc "Enqueue a review when a newly opened gate has enough PR identity."
  def maybe_enqueue(%Gate{class: class, pr_number: number} = gate)
      when class in @eligible_classes and is_integer(number) do
    case Gates.repo_for(gate) do
      repo when is_binary(repo) ->
        set_gate(gate.id, review_state: "queued")

        meta = %{
          "agent_id" => gate.agent_id,
          "legacy_routine_id" => gate.agent_id,
          "custode_kind" => "gate_review"
        }

        case Oban.insert(Custode.GateReviewJob.new(%{"gate_id" => gate.id}, meta: meta)) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            set_gate(gate.id, review_state: "enqueue_failed: #{inspect(reason)}")
        end

      _none ->
        set_gate(gate.id, review_state: "unavailable: repository unknown")
    end
  end

  def maybe_enqueue(%Gate{}), do: :ok

  @doc "Run or reuse the review attached to `gate_id`."
  def run(gate_id, opts \\ []) when is_integer(gate_id) do
    with %Gate{status: "open"} = gate <- Repo.get(Gate, gate_id),
         repo when is_binary(repo) <- Gates.repo_for(gate),
         {:ok, evidence} <- fetch_evidence(gate, repo, opts),
         {:ok, review, disposition} <- claim_review(gate, repo, evidence.pr.head_sha) do
      attach(gate, review, disposition)

      if disposition == :new do
        execute(review, gate, evidence, opts)
      else
        :ok
      end
    else
      nil -> :ok
      %Gate{} -> :ok
      {:limit, gate} -> set_gate(gate.id, review_state: "round_limit")
      {:error, reason} -> fail_gate(gate_id, reason)
      _other -> fail_gate(gate_id, :repository_unknown)
    end
  rescue
    exception ->
      fail_gate(gate_id, Exception.message(exception))
  end

  defp fetch_evidence(gate, repo, opts) do
    case Keyword.get(opts, :fetch) do
      fetch when is_function(fetch, 2) -> fetch.(gate, repo)
      nil -> fetch_from_repository(gate, repo)
    end
  end

  defp fetch_from_repository(gate, repo) do
    with {:ok, pr} <- Custode.Repository.view_pr(repo, gate.pr_number),
         true <- is_binary(pr.head_sha),
         {:ok, checks} <- Custode.Repository.pr_checks(repo, gate.pr_number),
         {:ok, diff} <- Custode.Repository.pr_diff(repo, gate.pr_number) do
      {:ok, %{pr: pr, checks: checks, diff: diff, intent: linked_intent(repo, pr)}}
    else
      false -> {:error, :head_sha_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp linked_intent(repo, pr) do
    case linked_issue(pr.body) do
      nil -> %{source: "pull_request", number: nil, title: pr.title, body: pr.body}
      number -> fetch_issue(repo, number, pr)
    end
  end

  defp linked_issue(body) when is_binary(body) do
    ~r/(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b/
    |> Regex.run(body, capture: :all_but_first)
    |> case do
      [number] -> String.to_integer(number)
      _none -> nil
    end
  end

  defp linked_issue(_body), do: nil

  defp fetch_issue(repo, number, pr) do
    case Custode.Repository.view_issue(repo, number) do
      {:ok, issue} -> Map.merge(issue, %{source: "issue"})
      {:error, _reason} -> %{source: "pull_request", number: nil, title: pr.title, body: pr.body}
    end
  end

  defp claim_review(gate, repo, head_sha) do
    case Repo.transaction(fn -> claim_review_locked(gate, repo, head_sha) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_review_locked(gate, repo, head_sha) do
    case Repo.get_by(Review, repo: repo, pr_number: gate.pr_number, head_sha: head_sha) do
      %Review{} = review ->
        {:ok, review, :reused}

      nil ->
        round = Repo.aggregate(review_query(repo, gate.pr_number), :count) + 1

        if round > max_rounds() do
          {:limit, gate}
        else
          insert_review(gate, repo, head_sha, round)
        end
    end
  end

  defp insert_review(gate, repo, head_sha, round) do
    author = Custode.Agents.provider(gate.agent_id)

    attrs = %{
      repo: repo,
      pr_number: gate.pr_number,
      head_sha: head_sha,
      author_provider: to_string(author),
      reviewer_provider: author |> opposite() |> to_string(),
      round: round,
      status: "pending"
    }

    case %Review{} |> Review.changeset(attrs) |> Repo.insert() do
      {:ok, review} ->
        {:ok, review, :new}

      {:error, _changeset} ->
        case Repo.get_by(Review, repo: repo, pr_number: gate.pr_number, head_sha: head_sha) do
          %Review{} = review -> {:ok, review, :reused}
          nil -> {:error, :review_claim_failed}
        end
    end
  end

  defp review_query(repo, number),
    do: from(r in Review, where: r.repo == ^repo and r.pr_number == ^number)

  defp max_rounds, do: Application.get_env(:custode, :gate_review_max_rounds, 3)

  defp opposite(:claude), do: :codex
  defp opposite(:codex), do: :claude

  defp attach(gate, review, disposition) do
    state =
      case {disposition, review.status} do
        {:reused, "completed"} -> "reused"
        {_disposition, status} -> status
      end

    gate
    |> Ecto.Changeset.change(review_id: review.id, review_state: state)
    |> Repo.update!()

    notify(gate.agent_id)
  end

  defp execute(review, gate, evidence, opts) do
    directory = Path.join(System.tmp_dir!(), "custode-gate-review-#{review.id}")
    File.mkdir_p!(directory)

    try do
      manifest = write_evidence!(directory, gate, review, evidence)
      digest = digest(Jason.encode!(manifest))
      update_review(review, evidence_digest: digest)

      case invoke(review, directory, opts) do
        {:ok, output} -> complete(review, output, manifest)
        {:error, reason} -> fail(review, reason)
      end
    rescue
      exception -> fail(review, Exception.message(exception))
    after
      File.rm_rf(directory)
    end
  end

  defp write_evidence!(directory, gate, review, evidence) do
    writes = %{
      "intent.md" => render_intent(evidence.intent),
      "gate.json" =>
        Jason.encode!(
          %{
            gate_id: gate.id,
            action: gate.detail,
            class: gate.class,
            repo: review.repo,
            pr_number: review.pr_number,
            head_sha: review.head_sha
          },
          pretty: true
        ),
      "checks.json" => Jason.encode!(evidence.checks, pretty: true),
      "diff.patch" => render_diff(evidence.diff)
    }

    for {path, content} <- writes, do: File.write!(Path.join(directory, path), content)

    manifest = %{
      "repo" => review.repo,
      "pr_number" => review.pr_number,
      "head_sha" => review.head_sha,
      "files" =>
        for path <- @evidence_files do
          %{"path" => path, "sha256" => digest(Map.fetch!(writes, path))}
        end
    }

    File.write!(Path.join(directory, "manifest.json"), Jason.encode!(manifest, pretty: true))

    File.write!(
      Path.join(directory, "review-output-schema.json"),
      Jason.encode!(schema(), pretty: true)
    )

    manifest
  end

  defp render_intent(intent) do
    """
    source: #{intent.source}
    number: #{intent[:number] || "unknown"}
    title: #{intent.title || "(untitled)"}

    #{intent.body || "(no body supplied)"}
    """
  end

  defp render_diff(%{files: files}) do
    Enum.map_join(files, "\n", fn file ->
      path = file[:path] || file[:filename] || file["path"] || file["filename"]
      patch = file[:patch] || file["patch"] || "(patch unavailable)"
      "diff --custode a/#{path} b/#{path}\n#{patch}\n"
    end)
  end

  defp invoke(review, directory, opts) do
    provider = String.to_existing_atom(review.reviewer_provider)
    args = provider_args(provider, directory)

    case Keyword.get(opts, :runner) do
      runner when is_function(runner, 2) -> runner.(provider, args)
      nil -> invoke_provider(provider, args, Keyword.get(opts, :job))
    end
  end

  defp provider_args(:claude, directory) do
    ObanClaude.Args.defaults(
      prompt: prompt(),
      working_dir: directory,
      permission_mode: :plan,
      max_turns: 6,
      timeout: 300_000,
      hermetic: true,
      no_session_persistence: true,
      allowed_tools: ["Read"],
      disallowed_tools: ["Bash", "WebFetch", "WebSearch"],
      json_schema: Jason.encode!(schema()),
      system_prompt: system_prompt()
    )
  end

  defp provider_args(:codex, directory) do
    ObanCodex.Args.defaults(
      prompt: prompt(),
      working_dir: directory,
      sandbox: :read_only,
      approval_policy: :never,
      timeout: 300_000,
      ephemeral: true,
      ignore_user_config: true,
      ignore_rules: true,
      search: :disabled,
      output_schema: Path.join(directory, "review-output-schema.json")
    )
  end

  defp invoke_provider(:claude, args, job) do
    case ObanClaude.run(args, job: job) do
      {:ok, result} -> {:ok, ObanClaude.structured(result)}
      {return, payload} -> {:error, {return, payload}}
    end
  end

  defp invoke_provider(:codex, args, job) do
    case ObanCodex.run(args, job: job) do
      {:ok, result} -> {:ok, ObanCodex.structured(result)}
      {return, payload} -> {:error, {return, payload}}
    end
  end

  defp system_prompt do
    """
    You are a sealed code reviewer. Read only the named evidence files. Do not
    use tools, network access, ambient repository instructions or prior session
    context. Report claims only when a cited evidence path and line range
    supports them. When the supplied files cannot support a claim, emit
    INSUFFICIENT_EVIDENCE instead of guessing.
    """
  end

  defp prompt do
    """
    Review the pull request represented by manifest.json. Read intent.md,
    gate.json, checks.json and diff.patch. Return only the JSON object required
    by review-output-schema.json. Each finding must cite one of those evidence
    paths and a concrete line range. Do not decide or execute the gate.
    """
  end

  defp schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["summary", "findings"],
      properties: %{
        summary: %{type: "string"},
        findings: %{
          type: "array",
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["severity", "category", "claim", "evidence", "proposed_fix"],
            properties: %{
              severity: %{type: "string", enum: @severities},
              category: %{type: "string"},
              claim: %{type: "string"},
              proposed_fix: %{type: "string"},
              evidence: %{
                type: "object",
                additionalProperties: false,
                required: ["files"],
                properties: %{
                  files: %{
                    type: "array",
                    items: %{
                      type: "object",
                      additionalProperties: false,
                      required: ["path", "lines"],
                      properties: %{path: %{type: "string"}, lines: %{type: "string"}}
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  defp complete(review, output, manifest) do
    case validate_output(output, manifest) do
      {:ok, summary, findings} ->
        now = DateTime.utc_now()

        update_review(review,
          status: "completed",
          summary: summary,
          findings: Jason.encode!(findings),
          completed_at: now
        )

        finish_attached(review.id, "completed")
        :ok

      {:error, reason} ->
        fail(review, reason)
    end
  end

  defp validate_output(%{"summary" => summary, "findings" => findings}, manifest)
       when is_binary(summary) and is_list(findings) do
    allowed = MapSet.new(Enum.map(manifest["files"], & &1["path"]))

    if Enum.all?(findings, &valid_finding?(&1, allowed)) do
      {:ok, summary, findings}
    else
      {:error, :invalid_findings}
    end
  end

  defp validate_output(_output, _manifest), do: {:error, :invalid_review_output}

  defp valid_finding?(finding, allowed) when is_map(finding) do
    severity = finding["severity"]
    files = get_in(finding, ["evidence", "files"])

    severity in @severities and present?(finding["category"]) and present?(finding["claim"]) and
      is_binary(finding["proposed_fix"]) and is_list(files) and
      valid_citations?(severity, files, allowed)
  end

  defp valid_finding?(_finding, _allowed), do: false

  defp valid_citations?("INSUFFICIENT_EVIDENCE", [], _allowed), do: true

  defp valid_citations?(_severity, files, allowed) do
    files != [] and
      Enum.all?(files, fn citation ->
        is_map(citation) and MapSet.member?(allowed, citation["path"]) and
          present?(citation["lines"])
      end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp fail(review, reason) do
    update_review(review,
      status: "failed",
      error: inspect(reason, printable_limit: 500),
      completed_at: DateTime.utc_now()
    )

    finish_attached(review.id, "failed")
    :ok
  end

  defp fail_gate(gate_id, reason) do
    set_gate(gate_id, review_state: "failed: #{inspect(reason, printable_limit: 300)}")
    :ok
  end

  defp update_review(review, attrs) do
    review |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp set_gate(gate_id, attrs) do
    Repo.update_all(from(g in Gate, where: g.id == ^gate_id), set: attrs)
    :ok
  end

  defp finish_attached(review_id, state) do
    query = from(g in Gate, where: g.review_id == ^review_id)
    agent_ids = Repo.all(from(g in query, select: g.agent_id))
    Repo.update_all(query, set: [review_state: state])
    agent_ids |> Enum.uniq() |> Enum.each(&notify/1)
  end

  defp notify(agent_id), do: Custode.PubSubBridge.broadcast({:status_changed, agent_id})

  defp digest(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
