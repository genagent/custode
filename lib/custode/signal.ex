defmodule Custode.Signal do
  @moduledoc """
  One agent's current state, as the operator needs to read it (#296).

  A signal is DERIVED and never stored. `Custode.Attention.resolve/2` computes
  it from state the fleet already keeps -- the gen_statem status, the durable
  gate row, the spend ledger, the cached GitHub overview -- so there is no
  table here and no migration behind it. Persisting attention would mean
  keeping it in sync with the five sources it summarises, and a stale
  needs-you badge is worse than none.

  ## The shape

  Every signal answers three questions in one struct:

    * WHAT is going on -- `kind`, and the `group` it collapses into.
    * WHY the operator should care -- `headline` and `detail`, already written
      as human sentences, because a caller that has to phrase the reason is a
      caller that will phrase it differently from the next one.
    * WHAT WOULD CLEAR IT -- `resolving`, a list of offered actions.

  `resolving` is the field that earns the struct. A row renders its own
  buttons from it, so adding a signal kind does not mean adding a template
  branch to every surface that draws signals. The list is ordered: the first
  entry is the action the operator most likely wants.

  ## Kinds and groups

  Kinds are ranked; groups are how they collapse on a page. The mapping is
  fixed in `Custode.Attention` (see its `@precedence`), not chosen per call
  site, so the fleet page, the inbox and the CLI cannot disagree about what
  counts as needing a human.

      :needs_answer  :approval  :rail_hit  :stalled  -> :needs_you
      :red_check                                     -> :watching
      :working                                       -> :working
      :scheduled                                     -> :scheduled
      :quiet         :paused                         -> :quiet

  Two of those placements are the whole point of separating kind from group.

  `:needs_you` means NOTHING PROGRESSES WITHOUT YOU. `:watching` means the
  fleet noticed something and is not blocked on a human for it. A red check
  belongs in the second: an agent that beats daily will look at it on its next
  beat, so counting it as a thing the operator owes is how a needs-you group
  stops being believed.

  `:paused` sits in `:quiet`. An agent the operator stopped on purpose is not
  a problem to be solved, and the fleet page used to treat it as one
  (`CustodeWeb.Components.needs_attention?/1` counts `:paused`), which put a
  deliberate act in the same bucket as an open gate.
  """

  @typedoc "What the agent's state is, most-urgent first. See `Custode.Attention`."
  @type kind ::
          :needs_answer
          | :approval
          | :red_check
          | :rail_hit
          | :stalled
          | :working
          | :scheduled
          | :quiet
          | :paused

  @typedoc "How a kind collapses on a page."
  @type group :: :needs_you | :watching | :working | :scheduled | :quiet

  @typedoc "The within-kind tiebreak, ahead of staleness."
  @type urgency :: :high | :normal | :low

  @typedoc """
  An action offered as a way to clear the signal. `op` is a plain atom naming
  the thing to do; it is deliberately NOT an operation-registry reference,
  because that registry does not exist yet. When it does, this field is where
  it lands.
  """
  @type resolving_op :: %{label: String.t(), op: atom(), args: map()}

  @type t :: %__MODULE__{
          subject: String.t(),
          kind: kind(),
          group: group(),
          urgency: urgency(),
          headline: String.t(),
          detail: String.t() | nil,
          item: term(),
          raised_at: DateTime.t() | nil,
          resolving: [resolving_op()]
        }

  @enforce_keys [:subject, :kind, :group, :urgency, :headline]
  defstruct [
    :subject,
    :kind,
    :group,
    :urgency,
    :headline,
    :detail,
    :item,
    :raised_at,
    resolving: []
  ]

  @doc """
  Whether this signal is one the operator has to act on.

  The one predicate every surface should use instead of re-deriving the
  question from a status atom.

      iex> signal = %Custode.Signal{
      ...>   subject: "adrs", kind: :needs_answer, group: :needs_you,
      ...>   urgency: :high, headline: "asked you a question"
      ...> }
      iex> Custode.Signal.needs_you?(signal)
      true
  """
  @spec needs_you?(t()) :: boolean()
  def needs_you?(%__MODULE__{group: group}), do: group == :needs_you
end
