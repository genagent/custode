defmodule Custode.Workflow do
  @moduledoc """
  A workflow definition: data, not a script (design/005, #271).

  A workflow is a named list of stages; a stage is a barrier holding one or
  more nodes; a node is one `--json-schema` claude run. Nothing here
  executes anything -- this module is the definition and its validation, the
  vocabulary the runner (a later slice) walks.

  Data rather than a script because Oban rows are already the journal: a
  node is one job, its structured result persists (`Custode.Workflow.Results`),
  and resume-after-restart is "enqueue the nodes without a persisted result".
  Arbitrary control flow would need a replay machinery custode does not need.

      %Custode.Workflow{
        name: "backlog-sweep",
        stages: [
          %Stage{name: :mine, nodes: [spec_node, docs_node, code_node]},
          %Stage{name: :merge, nodes: [merge_node], effort: "high"},
          %Stage{name: :verify, per_item: true, nodes: [verify_template]}
        ]
      }

  ## Stages are barriers

  A stage starts when the previous one has all its results. With the
  `:workflows` queue at concurrency 1 the pipeline-vs-barrier distinction
  costs nothing, and barriers are the simpler model: a downstream prompt can
  assume every upstream digest exists.

  ## Node names are unique workflow-wide

  Results are keyed by `{workflow_run, node_name, args_hash}`, so two nodes
  sharing a name in different stages would collide in the results table and
  a resume would skip the second because the first already wrote a row.
  `new/2` refuses that rather than leaving it to be discovered mid-run.

  ## per_item stages

  A `per_item: true` stage fans out over the previous stage's merged items:
  its single node is a TEMPLATE, instantiated once per item by the runner.
  It cannot be the first stage (nothing upstream to fan out over) and it
  carries exactly one node. The instantiated node names are the runner's to
  derive; the definition only says "one per item".
  """

  alias Custode.Workflow.Node
  alias Custode.Workflow.Stage

  @enforce_keys [:name, :stages]
  defstruct [:name, :stages, model: nil, effort: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          stages: [Stage.t()],
          model: String.t() | nil,
          effort: String.t() | nil
        }

  defmodule Node do
    @moduledoc """
    One node of a workflow: a prompt template plus the JSON schema its result
    must satisfy, and optional model/effort overrides.

    `prompt` is a template, not a rendered prompt -- the runner renders it
    with the repo, the roster context, and the DIGESTS of upstream results
    (digests, not transcripts, so late-stage prompts stay bounded).
    `schema` is the `--json-schema` map that forces the node's result into a
    shape the next stage can read without parsing prose (#120).
    """
    @enforce_keys [:name, :prompt, :schema]
    defstruct [:name, :prompt, :schema, model: nil, effort: nil]

    @type t :: %__MODULE__{
            name: atom(),
            prompt: String.t(),
            schema: map(),
            model: String.t() | nil,
            effort: String.t() | nil
          }
  end

  defmodule Stage do
    @moduledoc """
    One barrier of a workflow: a name, its nodes, and optional model/effort
    defaults its nodes inherit. `per_item: true` marks a fan-out stage whose
    single node is instantiated once per item produced upstream.
    """
    @enforce_keys [:name, :nodes]
    defstruct [:name, :nodes, per_item: false, model: nil, effort: nil]

    @type t :: %__MODULE__{
            name: atom(),
            nodes: [Custode.Workflow.Node.t()],
            per_item: boolean(),
            model: String.t() | nil,
            effort: String.t() | nil
          }
  end

  @doc """
  Build a validated workflow. Returns `{:error, reason}` for a definition
  the runner could not walk -- a definition is checked once, here, rather
  than half-run and abandoned.
  """
  @spec new(String.t(), [Stage.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(name, stages, opts \\ []) do
    workflow = %__MODULE__{
      name: name,
      stages: stages,
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort)
    }

    case validate(workflow) do
      :ok -> {:ok, workflow}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Same as `new/3`, raising on an invalid definition."
  @spec new!(String.t(), [Stage.t()], keyword()) :: t()
  def new!(name, stages, opts \\ []) do
    case new(name, stages, opts) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise ArgumentError, "invalid workflow #{inspect(name)}: #{reason}"
    end
  end

  @doc """
  Check a definition. `:ok` or `{:error, reason}` naming the first problem.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = workflow) do
    with :ok <- validate_name(workflow.name),
         :ok <- validate_stages(workflow.stages),
         :ok <- validate_first_stage(workflow.stages),
         :ok <- validate_unique(Enum.map(workflow.stages, & &1.name), "stage"),
         :ok <- validate_unique(Enum.map(nodes(workflow), & &1.name), "node") do
      each(workflow.stages, &validate_stage/1, &"stage #{inspect(&1.name)}")
    end
  end

  @doc "Every node in the workflow, in stage order."
  @spec nodes(t()) :: [Node.t()]
  def nodes(%__MODULE__{stages: stages}), do: Enum.flat_map(stages, & &1.nodes)

  @doc """
  The number of nodes a run will enqueue, or `:unknown` when the workflow
  fans out -- a `per_item` stage's node count is only known once the stage
  before it has merged. The launch gate's spend estimate reads this, and it
  says so rather than quoting a count it cannot know (#141's no-silent-caps
  rule applied to estimates).
  """
  @spec node_count(t()) :: non_neg_integer() | :unknown
  def node_count(%__MODULE__{stages: stages} = workflow) do
    if Enum.any?(stages, & &1.per_item),
      do: :unknown,
      else: length(nodes(workflow))
  end

  @doc """
  The count a launch estimate can stand behind: `{known, fans_out?}`.

  `known` counts the nodes of every fixed stage -- the floor a run will
  certainly enqueue. `fans_out?` says whether any stage expands over merged
  items, in which case the floor is a floor and nothing more. `node_count/1`
  answers `:unknown` in that case, which is honest but leaves a gate card
  with no number at all; this gives it the part that IS knowable and the
  flag that says the rest is not (#141's no-silent-caps rule: the estimate
  states its own limit rather than quoting a total it cannot know).
  """
  @spec node_floor(t()) :: {non_neg_integer(), boolean()}
  def node_floor(%__MODULE__{stages: stages}) do
    fixed = Enum.reject(stages, & &1.per_item)
    {Enum.sum(Enum.map(fixed, &length(&1.nodes))), Enum.any?(stages, & &1.per_item)}
  end

  @doc "The stage named `name`, or nil."
  @spec stage(t(), atom()) :: Stage.t() | nil
  def stage(%__MODULE__{stages: stages}, name), do: Enum.find(stages, &(&1.name == name))

  @doc """
  The model and effort a node runs with: the node's own overrides, else its
  stage's, else the workflow's, else nil (the fleet default). Resolved here
  so the runner never re-derives the cascade.
  """
  @spec settings(t(), Stage.t(), Node.t()) :: %{model: String.t() | nil, effort: String.t() | nil}
  def settings(%__MODULE__{} = workflow, %Stage{} = stage, %Node{} = node) do
    %{
      model: node.model || stage.model || workflow.model,
      effort: node.effort || stage.effort || workflow.effort
    }
  end

  defp validate_name(name) when is_binary(name) and name != "", do: :ok
  defp validate_name(_), do: {:error, "name must be a non-empty string"}

  defp validate_stages([%Stage{} | _] = stages) do
    if Enum.all?(stages, &match?(%Stage{}, &1)),
      do: :ok,
      else: {:error, "stages must all be %Custode.Workflow.Stage{}"}
  end

  defp validate_stages(_), do: {:error, "a workflow needs at least one stage"}

  defp validate_first_stage([%Stage{per_item: true, name: name} | _]),
    do: {:error, "stage #{inspect(name)}: the first stage cannot be per_item"}

  defp validate_first_stage(_), do: :ok

  defp validate_stage(%Stage{} = stage) do
    with :ok <- validate_stage_name(stage.name),
         :ok <- validate_nodes(stage) do
      each(stage.nodes, &validate_node/1, &"node #{inspect(&1.name)}")
    end
  end

  # the first failure wins, prefixed with which stage or node it came from
  defp each(items, validate, label) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{label.(item)}: #{reason}"}}
      end
    end)
  end

  defp validate_stage_name(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_stage_name(_), do: {:error, "name must be an atom"}

  defp validate_nodes(%Stage{per_item: true, nodes: [%Node{}]}), do: :ok

  defp validate_nodes(%Stage{per_item: true}),
    do: {:error, "a per_item stage carries exactly one node, the per-item template"}

  defp validate_nodes(%Stage{nodes: [%Node{} | _] = nodes}) do
    if Enum.all?(nodes, &match?(%Node{}, &1)),
      do: :ok,
      else: {:error, "nodes must all be %Custode.Workflow.Node{}"}
  end

  defp validate_nodes(%Stage{}), do: {:error, "a stage needs at least one node"}

  defp validate_node(%Node{} = node) do
    cond do
      not is_atom(node.name) or is_nil(node.name) ->
        {:error, "name must be an atom"}

      not is_binary(node.prompt) or node.prompt == "" ->
        {:error, "prompt must be a non-empty string"}

      not is_map(node.schema) ->
        {:error, "schema must be a map (the --json-schema)"}

      not optional_string?(node.model) ->
        {:error, "model must be a string or nil"}

      not optional_string?(node.effort) ->
        {:error, "effort must be a string or nil"}

      true ->
        :ok
    end
  end

  defp validate_node(_), do: {:error, "nodes must all be %Custode.Workflow.Node{}"}

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp validate_unique(names, label) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [dupe | _] -> {:error, "duplicate #{label} name #{inspect(dupe)}"}
    end
  end
end
