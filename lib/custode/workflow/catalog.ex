defmodule Custode.Workflow.Catalog do
  @moduledoc """
  The named workflows custode can run (design/005, #271).

  A small code-reviewed catalog, not user-authored orchestration: launching one
  is a name, not a script. `backlog-sweep` is the first entry -- the port of the
  five-miner deep dig, and the one whose output feeds the fleet directly.
  `deep-report` is the second (slice 5, #275), the research shape: its output
  is a document rather than a list of items.

  Two entries, and what the second one asked of the shape is small: a
  `report:` declaration on the workflow saying which node's result carries
  the markdown. Everything else -- stages as barriers, per-item fan-out,
  digests, the args-hash resume, the rail -- carried over untouched, which is
  the evidence position 4 wanted for the catalog being a catalog rather than
  one workflow with a name.

  `Application.get_env(:custode, :extra_workflows, %{})` merges over the
  built-ins. That is the test seam -- a three-node toy workflow walks the
  runner without rendering `backlog-sweep`'s prompts -- and it is deliberately
  not a user-facing extension point: a workflow that needs to exist belongs in
  this file, where it is reviewed.
  """

  alias Custode.Workflow
  alias Custode.Workflow.Node
  alias Custode.Workflow.Stage

  @doc "Every catalog entry, by name."
  def all do
    Map.merge(built_in(), Application.get_env(:custode, :extra_workflows, %{}))
  end

  @doc "The names in the catalog, sorted."
  def names, do: all() |> Map.keys() |> Enum.sort()

  @doc "One entry by name: `{:ok, workflow}` or `:error`."
  def fetch(name) when is_binary(name), do: Map.fetch(all(), name)

  @doc "One entry by name, raising when there is none."
  def fetch!(name) do
    case fetch(name) do
      {:ok, workflow} -> workflow
      :error -> raise ArgumentError, "no workflow named #{inspect(name)}"
    end
  end

  defp built_in,
    do: %{"backlog-sweep" => backlog_sweep(), "deep-report" => deep_report()}

  # ---------------------------------------------------------------------------
  # backlog-sweep
  # ---------------------------------------------------------------------------

  @doc """
  The five-miner deep dig: mine the repo from five independent angles, merge
  and dedup, verify each survivor adversarially, draft the ones that live, and
  critique the batch.

  Verify sits before draft on purpose: an adversarial pass kills items before
  any drafting effort is spent on them. Verifiers must cite evidence to drop
  and default to keep, so the pass removes what is demonstrably wrong rather
  than what is merely unfamiliar.
  """
  def backlog_sweep do
    Workflow.new!(
      "backlog-sweep",
      [
        %Stage{
          name: :mine,
          nodes: [
            miner(
              :spec,
              "the design notes and the ROADMAP",
              """
              Read the design notes under `design/` and `ROADMAP.md`. Find work
              they COMMIT to that the code has not done: a slice named and not
              built, a stated position the code contradicts, a follow-up a note
              defers and nothing tracks.
              """
            ),
            miner(
              :docs,
              "the README, guides, and moduledocs",
              """
              Read `README.md`, anything under `guides/` and `docs/`, and the
              moduledocs of the main modules. Find where the documentation and
              the code disagree: a documented flag that does not exist, a
              behaviour described one way and implemented another, an entry
              point with no documentation at all.
              """
            ),
            miner(
              :code,
              "the code itself",
              """
              Read the code. Find defects and near-defects: an error path that
              cannot work, a TODO with a real bug behind it, a duplicated rule
              that has already drifted, a module that has outgrown its purpose.
              Prefer specific and small over sweeping.
              """
            ),
            miner(
              :issues,
              "the closed issues and recent history",
              """
              Read the recently closed issues (`gh issue list --state closed
              --limit 60`) and the recent commit history. Find what closing them
              left behind: a fix applied in one place and not its twin, a
              follow-up an issue promised, a regression a later change
              reintroduced.
              """
            ),
            miner(
              :gaps,
              "what nobody has looked at",
              """
              Look adversarially for what the other angles will miss. Where is
              there no test? What fails only on restart, only when empty, only
              on the second run? What does the project assume about its
              environment that it never checks?
              """
            )
          ]
        },
        %Stage{
          name: :merge,
          effort: "high",
          nodes: [
            %Node{
              name: :merge,
              schema: items_schema(),
              prompt: """
              You are merging the findings of five independent miners over the
              repository <%= @repo %>. Each mined a different angle, blind
              to the others, so the same problem may appear more than once in
              different words.

              Their findings:

              <%= @digests %>

              Merge them into one deduplicated list. Two findings are the same
              item when fixing one would fix the other, whatever they call it.
              When you merge, keep the strongest evidence from each. Drop
              nothing on grounds of taste -- verification is the next stage and
              it is not your job.

              Order the list by how much the project gains from the item,
              highest first.
              """
            }
          ]
        },
        %Stage{
          name: :verify,
          per_item: true,
          nodes: [
            %Node{
              name: :verify,
              schema: verify_schema(),
              prompt: """
              Try to REFUTE this candidate finding against the repository
              <%= @repo %>:

              <%= @item %>

              Read the code, the tests, and the history it names. Then decide:

              * `drop` -- only with a citation. Name the file, line, test, or
                commit that shows the finding is wrong, already fixed, or
                impossible. "I could not confirm it" is not a citation.
              * `keep` -- everything else. The default verdict is keep; an item
                you are unsure about is the next stage's problem, not a drop.

              Return `items: []` when you drop it, and `items: [the finding]`
              when you keep it -- corrected, if reading the code sharpened it.
              """
            }
          ]
        },
        %Stage{
          name: :draft,
          per_item: true,
          nodes: [
            %Node{
              name: :draft,
              schema: issue_schema(),
              prompt: """
              Draft a GitHub issue for this verified finding in
              <%= @repo %>:

              <%= @item %>

              Match the repository: read `.github/ISSUE_TEMPLATE` if it exists,
              use the repo's own labels (`gh label list`), and give it a
              CONVENTIONAL title (`feat:`, `fix:`, `docs:`, `test:`, `chore:`)
              -- custode's title policy applies to issues, and a non-conventional
              title is refused at filing.

              The body states what is wrong, where, and what evidence says so.
              No editorialising, no marketing tone, no em dashes. If the fix is
              larger than one sitting, say what its first slice is.

              Draft only. Do not file anything.
              """
            }
          ]
        },
        %Stage{
          name: :critique,
          effort: "high",
          nodes: [
            %Node{
              name: :critic,
              schema: critique_schema(),
              prompt: """
              Here are the issues drafted for <%= @repo %> by a deep sweep:

              <%= @digests %>

              Critique the BATCH, not each issue. What would a maintainer
              reading all of these at once object to? Look for: items that
              should be one issue, items too vague to act on, items that
              propose work the project has already decided against, and
              anything the sweep clearly missed given what it did find.

              Say plainly which drafts you would not file, and why.
              """
            }
          ]
        }
      ],
      model: "sonnet"
    )
  end

  defp miner(name, angle, instructions) do
    %Node{
      name: name,
      schema: items_schema(),
      prompt: """
      You are one of five miners sweeping the repository <%= @repo %> for
      work worth doing. Your angle is #{angle}. The other four are covering
      other angles and cannot see your findings, so cover yours completely
      rather than guessing at theirs.

      #{instructions}

      Read the repository. Cite what you find -- a path, a line, a commit, an
      issue number. A finding with no citation is a guess, and this stage does
      not produce guesses. Report nothing rather than padding the list.
      """
    }
  end

  # ---------------------------------------------------------------------------
  # deep-report
  # ---------------------------------------------------------------------------

  # What the report is ABOUT. A launch may pass `subject` in its context -- a
  # question, a technology, a decision the repo is facing -- and a launch that
  # passes nothing gets a report about the repository itself, which is the
  # honest reading of "run deep-report on genagent/custode" with no further
  # instruction.
  @subject ~S(<%= @context["subject"] || @repo %>)

  @doc """
  The research shape: search from four angles, confirm every claim against a
  primary source, analyse the survivors along four dimensions, and synthesise
  one markdown report.

  ## The verify stage runs the OTHER way round

  `backlog-sweep` verifies with default-keep: an item nobody could refute is
  the next stage's problem, because the cost of a doubtful issue is an
  operator reading it. Here the default is DROP. An unconfirmed claim in a
  report is a project that does not exist, a version that was never released,
  a benchmark nobody ran -- and the cost of that is a document that reads
  authoritative and is wrong. Same stage shape, inverted default, and the
  inversion is the point: it is what "the hallucination filter" means when
  the output is prose rather than a backlog.

  ## The report is data until the run ends

  The synthesis node returns its markdown inside its schema-forced result
  like any other node. `Custode.Workflow.Report` writes the file when the run
  completes -- nodes still write nothing (design/005's non-goal), and the
  report lands in custode's own tree rather than in the repository the run
  was reading.
  """
  def deep_report do
    Workflow.new!(
      "deep-report",
      [
        %Stage{
          name: :search,
          nodes: [
            angle(
              :prior_art,
              "what already exists",
              """
              Find what has already been built in this space: projects,
              libraries, products, papers. Name each one exactly as its own
              source names it, and give the source you found it in -- a
              repository URL, a package page, a paper. Prefer things you can
              point at over things you remember.
              """
            ),
            angle(
              :practice,
              "how it is actually done",
              """
              Find how practitioners handle this today: documented patterns,
              conventions, the shape working systems settle into. What does
              the documentation of the tools involved actually say, and where
              does practice differ from what the documentation recommends?
              """
            ),
            angle(
              :sources,
              "the primary material",
              """
              Go to the primary sources: specifications, official
              documentation, release notes, the code of the systems involved.
              Report what they SAY, with the location. This angle exists so
              the later stages have something to check the others against.
              """
            ),
            angle(
              :dissent,
              "the case against",
              """
              Look for the counter-evidence the other angles will not go
              looking for: post-mortems, deprecations, migrations away, known
              failure modes, arguments that the obvious approach is wrong. A
              landscape with no dissent in it has not been read carefully.
              """
            )
          ]
        },
        %Stage{
          name: :confirm,
          per_item: true,
          nodes: [
            %Node{
              name: :confirm,
              schema: confirm_schema(),
              prompt: """
              CONFIRM this claim, gathered while researching #{@subject}:

              <%= @item %>

              Go to the source. If it names a project, fetch the project --
              its repository, its package page, its documentation -- and
              confirm it exists and is what the claim says it is. If it names
              a version, a date, a benchmark or a quote, find the primary
              source that carries it.

              Then decide:

              * `confirmed` -- you reached a primary source and it says what
                the claim says. Return `items: [the claim]`, corrected where
                the source disagreed with the detail, with the source you
                reached recorded in its `sources`.
              * `unconfirmed` -- everything else, INCLUDING a claim that is
                merely plausible and a source you could not reach. Return
                `items: []`.

              The default verdict is unconfirmed. A report that names a
              project nobody could fetch is worse than a shorter report, so
              say why in `reason` and drop it.
              """
            }
          ]
        },
        %Stage{
          name: :analyse,
          nodes: [
            dimension(
              :maturity,
              "maturity",
              """
              How settled is each confirmed thing? Read for activity, release
              cadence, breaking-change history, how many people depend on it.
              Say which of these you would build on this year and which are
              interesting but early.
              """
            ),
            dimension(
              :fit,
              "fit",
              """
              What of this applies to <%= @repo %> as it actually is? Read
              the repository before answering -- its stack, its size, its
              constraints. An option that fits a different project is not fit
              here, and saying so is more useful than listing it again.
              """
            ),
            dimension(
              :risk,
              "risk",
              """
              What goes wrong? Read the confirmed material for the failure
              modes it reports: what breaks under load, what is hard to
              migrate off, what depends on one maintainer, what the dissent
              angle found. Name the risk and what it would cost.
              """
            ),
            dimension(
              :tradeoffs,
              "trade-offs",
              """
              Where do the confirmed findings genuinely disagree, and what is
              the trade being made in each case? Name the axes a decision
              would move along rather than declaring a winner -- the
              synthesis stage does that, and it needs the axes from you.
              """
            )
          ]
        },
        %Stage{
          name: :synthesis,
          effort: "high",
          nodes: [
            %Node{
              name: :report,
              schema: report_schema(),
              prompt: """
              Write the report on #{@subject}.

              Everything below has been searched from four angles, confirmed
              against primary sources one claim at a time, and analysed along
              four dimensions:

              <%= @digests %>

              Write ONE standalone markdown document. It is read by someone
              who did not watch the run, so it stands on its own: what the
              question was, what is out there, what holds up, what it means
              for <%= @repo %>, and what you would do.

              Rules the document keeps:

              * Every project, version, and quote is one the confirm stage
                confirmed. Nothing new enters at synthesis -- if it was
                dropped, it is not in the report.
              * Cite sources inline, as links or paths.
              * Say what the run did NOT establish. An open question named is
                worth more than a paragraph of hedging.
              * Plain declarative prose. No marketing tone, no
                self-congratulation, no em dashes.

              Return the whole document as markdown in `report`. It is
              written to a file exactly as you return it, so it carries its
              own title and needs no wrapper.
              """
            }
          ]
        }
      ],
      model: "sonnet",
      report: %{node: :report, key: "report", filename: "report.md"}
    )
  end

  defp angle(name, angle, instructions) do
    %Node{
      name: name,
      schema: claims_schema(),
      prompt: """
      You are one of four researchers working on #{@subject}. Your angle is
      #{angle}. The other three cover other angles and cannot see your
      findings, so cover yours completely rather than guessing at theirs.

      #{instructions}

      Every finding is a CLAIM the next stage will try to confirm against a
      primary source, so record what you actually saw and where you saw it. A
      claim with no source is dropped unread, and a confident sentence about a
      project that turns out not to exist is the specific failure this
      workflow is built to catch. Report less rather than padding.
      """
    }
  end

  defp dimension(name, dimension, instructions) do
    %Node{
      name: name,
      schema: analysis_schema(),
      prompt: """
      You are analysing the CONFIRMED research on #{@subject} along one
      dimension: #{dimension}. Three others are taking the other dimensions.

      The confirmed findings:

      <%= @digests %>

      #{instructions}

      Work from what survived confirmation. A claim that was dropped was
      dropped for a reason, and reintroducing it here would put it in the
      report through the back door. Where the confirmed material does not
      answer your dimension, say so in `unknowns` rather than filling the
      gap.
      """
    }
  end

  # ---------------------------------------------------------------------------
  # schemas
  # ---------------------------------------------------------------------------

  # every stage that feeds a per_item stage produces `items`; the runner fans
  # out over exactly that key
  defp items_schema do
    item = %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "one line, conventional-commit style"},
        "kind" => %{
          "type" => "string",
          "enum" => ["bug", "gap", "docs", "test", "cleanup", "feature"]
        },
        "detail" => %{"type" => "string", "description" => "what is wrong and where"},
        "evidence" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "paths, lines, commits, issue numbers"
        },
        "confidence" => %{"type" => "string", "enum" => ["high", "medium", "low"]}
      },
      "required" => ["title", "detail", "evidence"]
    }

    %{
      "type" => "object",
      "properties" => %{"items" => %{"type" => "array", "items" => item}},
      "required" => ["items"]
    }
  end

  # the verdict rides at the top level, not on the item: it is a judgment ABOUT
  # the item, and `items` stays exactly the fan-out key the next stage reads --
  # empty when the verifier drops, one-long when it keeps
  defp verify_schema do
    base = items_schema()

    properties =
      Map.merge(base["properties"], %{
        "verdict" => %{"type" => "string", "enum" => ["keep", "drop"]},
        "reason" => %{
          "type" => "string",
          "description" => "the citation that justifies a drop"
        }
      })

    %{base | "properties" => properties, "required" => ["items", "verdict"]}
  end

  defp issue_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" => "conventional-commit style; the filing policy enforces it"
        },
        "body" => %{"type" => "string"},
        "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["title", "body"]
    }
  end

  # the research counterpart of items_schema: same `items` fan-out key, but a
  # claim carries the SOURCE it was read from rather than a repo path, because
  # that is what the confirm stage goes back to
  defp claims_schema do
    claim = %{
      "type" => "object",
      "properties" => %{
        "claim" => %{"type" => "string", "description" => "one sentence, stated plainly"},
        "names" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "the projects, papers, versions or people it names"
        },
        "detail" => %{"type" => "string"},
        "sources" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "URLs, paths, or document titles the claim was read from"
        }
      },
      "required" => ["claim", "detail", "sources"]
    }

    %{
      "type" => "object",
      "properties" => %{"items" => %{"type" => "array", "items" => claim}},
      "required" => ["items"]
    }
  end

  # the verdict rides at the top level for the same reason it does in
  # verify_schema -- `items` stays the fan-out key -- but the enum is the other
  # way round: confirmed keeps, and everything else drops
  defp confirm_schema do
    base = claims_schema()

    properties =
      Map.merge(base["properties"], %{
        "verdict" => %{"type" => "string", "enum" => ["confirmed", "unconfirmed"]},
        "reason" => %{
          "type" => "string",
          "description" => "the source that confirms it, or what could not be reached"
        }
      })

    %{base | "properties" => properties, "required" => ["items", "verdict", "reason"]}
  end

  defp analysis_schema do
    %{
      "type" => "object",
      "properties" => %{
        "dimension" => %{"type" => "string"},
        "assessment" => %{"type" => "string", "description" => "the dimension's answer, in prose"},
        "findings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "point" => %{"type" => "string"},
              "evidence" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["point"]
          }
        },
        "unknowns" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "what the confirmed material does not answer"
        }
      },
      "required" => ["assessment"]
    }
  end

  defp report_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string", "description" => "a paragraph, for the feed"},
        "report" => %{
          "type" => "string",
          "description" => "the whole document as markdown; written to the artifact file"
        },
        "open_questions" => %{"type" => "array", "items" => %{"type" => "string"}},
        "sources" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["title", "summary", "report"]
    }
  end

  defp critique_schema do
    %{
      "type" => "object",
      "properties" => %{
        "assessment" => %{"type" => "string"},
        "concerns" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "about" => %{"type" => "string", "description" => "which draft, or the batch"},
              "concern" => %{"type" => "string"}
            },
            "required" => ["about", "concern"]
          }
        },
        "would_not_file" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["assessment"]
    }
  end
end
