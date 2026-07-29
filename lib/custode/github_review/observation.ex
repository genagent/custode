defmodule Custode.GitHubReview.Observation do
  @moduledoc """
  Transport-neutral GitHub review evidence pinned to one pull-request head.

  Webhooks and periodic snapshots normalize into the same value. GitHub
  identifiers, rather than delivery order, define which feedback has already
  been consumed.
  """

  @kinds ~w(snapshot review_feedback check_run conflict)
  @failing_conclusions ~w(action_required cancelled failure startup_failure timed_out)

  @enforce_keys [
    :repository,
    :pull_request_number,
    :head_sha,
    :external_updated_at,
    :kind,
    :comments,
    :reviews,
    :checks,
    :conflict,
    :item_tokens,
    :external_identity
  ]
  defstruct @enforce_keys ++ [:delivery_id]

  @type t :: %__MODULE__{}

  @spec from_snapshot(String.t(), pos_integer(), map()) :: {:ok, t()} | {:error, term()}
  def from_snapshot(repository, number, snapshot) do
    pull_request = value(snapshot, :pull_request) || %{}
    head_sha = value(pull_request, :head_sha)

    reviews =
      snapshot
      |> value(:reviews, [])
      |> Enum.filter(fn review ->
        commit_id = value(review, :commit_id)
        is_nil(commit_id) or commit_id == head_sha
      end)

    attrs = %{
      repository: repository,
      pull_request_number: number,
      head_sha: head_sha,
      base_sha: value(pull_request, :base_sha),
      external_updated_at: latest_timestamp(pull_request, reviews, snapshot),
      kind: "snapshot",
      comments: value(snapshot, :comments, []),
      reviews: reviews,
      checks: value(snapshot, :checks, []),
      conflict: conflict(pull_request)
    }

    new(attrs)
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, comments} <- normalize_items(value(attrs, :comments, []), :comments),
         {:ok, reviews} <- normalize_items(value(attrs, :reviews, []), :reviews),
         {:ok, checks} <- normalize_items(value(attrs, :checks, []), :checks) do
      build(attrs, comments, reviews, checks)
    end
  end

  def new(_attrs), do: {:error, :invalid_github_observation}

  defp build(attrs, comments, reviews, checks) do
    observation = %{
      repository: value(attrs, :repository),
      pull_request_number: value(attrs, :pull_request_number),
      head_sha: value(attrs, :head_sha),
      external_updated_at: value(attrs, :external_updated_at),
      kind: normalize_kind(value(attrs, :kind)),
      delivery_id: value(attrs, :delivery_id),
      comments: comments,
      reviews: reviews,
      checks: checks,
      conflict: normalize_conflict(value(attrs, :conflict), value(attrs, :base_sha))
    }

    with :ok <- validate(observation) do
      tokens = item_tokens(observation)
      external_identity = external_identity(observation, tokens)

      {:ok,
       struct!(
         __MODULE__,
         observation
         |> Map.put(:item_tokens, tokens)
         |> Map.put(:external_identity, external_identity)
       )}
    end
  end

  @spec without_consumed(t(), MapSet.t(String.t())) :: t()
  def without_consumed(%__MODULE__{} = observation, consumed) do
    filtered = %{
      observation
      | comments: reject_consumed("comment", observation.comments, consumed),
        reviews: reject_consumed("review", observation.reviews, consumed),
        checks: reject_consumed("check", observation.checks, consumed),
        conflict: filter_conflict(observation, consumed)
    }

    tokens = item_tokens(filtered)
    %{filtered | item_tokens: tokens}
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = observation), do: observation.item_tokens == []

  @spec action(t()) :: map()
  def action(%__MODULE__{} = observation) do
    conflict_action(observation) || feedback_action(observation)
  end

  defp conflict_action(observation) do
    cond do
      conflicting?(observation) and is_binary(observation.conflict[:base_sha]) ->
        %{
          kind: :repair,
          phase: "conflict_ready",
          active_phase: "resolving_conflict",
          disposition: "mechanical_repair",
          handler: "git_replay",
          reason: "replay the published change onto the observed base"
        }

      conflicting?(observation) ->
        semantic_action(
          "conflict_ready",
          "resolving_conflict",
          "conflict resolution requires model judgment"
        )

      true ->
        nil
    end
  end

  defp feedback_action(observation) do
    failures = failed_checks(observation)

    cond do
      failures != [] and format_only?(failures) ->
        %{
          kind: :repair,
          phase: "feedback_ready",
          active_phase: "handling_feedback",
          disposition: "mechanical_repair",
          handler: "elixir_format",
          reason: "all newly failed checks are formatter checks"
        }

      failures != [] ->
        semantic_action(
          "feedback_ready",
          "handling_feedback",
          "failed checks require focused semantic repair"
        )

      changes_requested?(observation) or actionable_comments?(observation) ->
        semantic_action(
          "feedback_ready",
          "handling_feedback",
          "requested changes require focused semantic repair"
        )

      true ->
        %{kind: :wait, reason: "no actionable review change"}
    end
  end

  @spec render(t()) :: map()
  def render(%__MODULE__{} = observation) do
    observation
    |> Map.from_struct()
    |> Map.update!(:conflict, &Map.new/1)
  end

  defp semantic_action(phase, active_phase, reason) do
    %{
      kind: :repair,
      phase: phase,
      active_phase: active_phase,
      disposition: "semantic_repair",
      handler: "claude",
      reason: reason
    }
  end

  defp validate(observation) do
    with :ok <- nonempty(:repository, observation.repository),
         :ok <- positive(:pull_request_number, observation.pull_request_number),
         :ok <- nonempty(:head_sha, observation.head_sha),
         :ok <- inclusion(:kind, observation.kind, @kinds),
         :ok <- timestamp(observation.external_updated_at),
         :ok <- item_ids(:comments, observation.comments),
         :ok <- item_ids(:reviews, observation.reviews),
         :ok <- item_ids(:checks, observation.checks) do
      relevant_items(observation)
    end
  end

  defp relevant_items(%{kind: "review_feedback", comments: [], reviews: []}),
    do: {:error, {:invalid_github_observation, :review_identifier_required}}

  defp relevant_items(%{kind: "check_run", checks: []}),
    do: {:error, {:invalid_github_observation, :check_identifier_required}}

  defp relevant_items(%{kind: "conflict", conflict: %{status: "unknown"}}),
    do: {:error, {:invalid_github_observation, :conflict_state_required}}

  defp relevant_items(_observation), do: :ok

  defp item_ids(_name, []), do: :ok

  defp item_ids(name, items) do
    if Enum.all?(items, &(not is_nil(value(&1, :id)))),
      do: :ok,
      else: {:error, {:invalid_github_observation, {name, :identifier_required}}}
  end

  defp item_tokens(observation) do
    comments = Enum.map(observation.comments, &item_token("comment", &1))
    reviews = Enum.map(observation.reviews, &item_token("review", &1))
    checks = Enum.map(observation.checks, &item_token("check", &1))

    (comments ++ reviews ++ checks ++ conflict_tokens(observation))
    |> Enum.sort()
  end

  defp item_token("comment", item) do
    token("comment", [
      value(item, :id),
      value(item, :updated_at) || value(item, :created_at)
    ])
  end

  defp item_token("review", item) do
    token("review", [
      value(item, :id),
      value(item, :submitted_at) || value(item, :updated_at),
      value(item, :state)
    ])
  end

  defp item_token("check", item) do
    token("check", [
      value(item, :id),
      value(item, :status),
      value(item, :conclusion),
      value(item, :completed_at) || value(item, :started_at) || value(item, :updated_at)
    ])
  end

  defp conflict_tokens(%{conflict: %{status: "unknown"}}), do: []

  defp conflict_tokens(observation) do
    [
      token("conflict", [
        observation.conflict[:status],
        observation.conflict[:base_sha],
        observation.head_sha
      ])
    ]
  end

  defp reject_consumed(prefix, items, consumed) do
    Enum.reject(items, &MapSet.member?(consumed, item_token(prefix, &1)))
  end

  defp filter_conflict(observation, consumed) do
    case conflict_tokens(observation) do
      [token] ->
        if MapSet.member?(consumed, token),
          do: %{status: "unknown", base_sha: nil},
          else: observation.conflict

      _tokens ->
        observation.conflict
    end
  end

  defp external_identity(observation, tokens) do
    digest =
      {
        observation.repository,
        observation.pull_request_number,
        observation.head_sha,
        observation.external_updated_at,
        observation.kind,
        tokens
      }
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "github:#{observation.repository}:pr:#{observation.pull_request_number}:observation:#{digest}"
  end

  defp failed_checks(observation) do
    Enum.filter(observation.checks, fn check ->
      normalize_text(value(check, :conclusion)) in @failing_conclusions
    end)
  end

  defp format_only?(checks) do
    Enum.all?(checks, fn check ->
      name = check |> value(:name) |> normalize_text()
      String.contains?(name, ["format", "formatter", "mix format"])
    end)
  end

  defp changes_requested?(observation) do
    Enum.any?(observation.reviews, fn review ->
      normalize_text(value(review, :state)) == "changes_requested"
    end)
  end

  defp actionable_comments?(observation) do
    Enum.any?(observation.comments, fn comment ->
      body = comment |> value(:body) |> to_string() |> String.trim()
      normalized = String.downcase(body)

      body != "" and
        not String.starts_with?(normalized, [
          "review: lgtm",
          "review: ok",
          "review: approved"
        ])
    end)
  end

  defp conflicting?(observation), do: observation.conflict[:status] == "conflicting"

  defp conflict(pull_request) do
    status =
      cond do
        value(pull_request, :mergeable) == false -> "conflicting"
        normalize_text(value(pull_request, :mergeable_state)) == "dirty" -> "conflicting"
        value(pull_request, :mergeable) == true -> "clean"
        true -> "unknown"
      end

    %{status: status, base_sha: value(pull_request, :base_sha)}
  end

  defp normalize_conflict(nil, base_sha), do: %{status: "unknown", base_sha: base_sha}

  defp normalize_conflict(conflict, base_sha) when is_map(conflict) or is_list(conflict) do
    conflict = Map.new(conflict)

    %{
      status: normalize_conflict_status(value(conflict, :status) || value(conflict, :state)),
      base_sha: value(conflict, :base_sha) || base_sha
    }
  end

  defp normalize_conflict(conflict, base_sha) when is_boolean(conflict) do
    %{status: if(conflict, do: "conflicting", else: "clean"), base_sha: base_sha}
  end

  defp normalize_conflict(_conflict, base_sha), do: %{status: "unknown", base_sha: base_sha}

  defp normalize_conflict_status(value) do
    case normalize_text(value) do
      status when status in ~w(conflict conflicting dirty) -> "conflicting"
      status when status in ~w(clean mergeable) -> "clean"
      _other -> "unknown"
    end
  end

  defp latest_timestamp(pull_request, reviews, snapshot) do
    timestamps =
      [
        value(pull_request, :updated_at)
        | Enum.map(value(snapshot, :comments, []), fn item ->
            value(item, :updated_at) || value(item, :created_at)
          end) ++
            Enum.map(reviews, &(value(&1, :submitted_at) || value(&1, :updated_at))) ++
            Enum.map(value(snapshot, :checks, []), fn item ->
              value(item, :completed_at) || value(item, :started_at) || value(item, :updated_at)
            end)
      ]
      |> Enum.filter(&is_binary/1)

    case timestamps do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp normalize_items(items, field) when is_list(items) do
    if Enum.all?(items, &(is_map(&1) or is_list(&1))) do
      {:ok, Enum.map(items, &Map.new/1)}
    else
      {:error, {:invalid_github_observation, field}}
    end
  end

  defp normalize_items(_items, field), do: {:error, {:invalid_github_observation, field}}

  defp normalize_kind(kind) do
    case normalize_text(kind) do
      "review" -> "review_feedback"
      "comment" -> "review_feedback"
      "check" -> "check_run"
      kind -> kind
    end
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: value |> to_string() |> String.downcase()

  defp nonempty(_field, value) when is_binary(value) and value != "", do: :ok
  defp nonempty(field, _value), do: {:error, {:invalid_github_observation, field}}

  defp positive(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive(field, _value), do: {:error, {:invalid_github_observation, field}}

  defp inclusion(field, value, values) do
    if value in values, do: :ok, else: {:error, {:invalid_github_observation, field}}
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _invalid -> {:error, {:invalid_github_observation, :external_updated_at}}
    end
  end

  defp timestamp(_value), do: {:error, {:invalid_github_observation, :external_updated_at}}

  defp token(prefix, parts), do: Enum.join([prefix | Enum.map(parts, &to_string/1)], ":")

  defp value(nil, _key), do: nil
  defp value(map, key), do: value(map, key, nil)

  defp value(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
