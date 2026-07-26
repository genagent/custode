defmodule Custode.Workflow.Catalog do
  @moduledoc """
  The named workflows custode can run (design/005, #271).

  A small code-reviewed catalog, not user-authored orchestration: launching one
  is a name, not a script. `backlog-sweep` is the first entry -- the port of the
  five-miner deep dig, and the one whose output feeds the fleet directly.
  `deep-report` is the second, and it waits for slice 5 by design: two entries
  prove the catalog shape, and proving it against a half-built runner proves
  nothing.

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

  defp built_in, do: %{"backlog-sweep" => backlog_sweep()}

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
