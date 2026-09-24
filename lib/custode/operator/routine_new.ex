defmodule Custode.Operator.RoutineNew do
  @moduledoc "Plans and creates a routine from the shared setup form."

  alias Custode.Config.WriteBack
  alias Custode.Operations.Fleet.ProvisionOwnedCheckout
  alias Custode.{OwnedCheckout, Routine}
  alias Oban.Cron.Expression

  @fields ~w(id kind provider profile repo checkout_mode working_dir tags cadence cron prompt model effort)
  @cadences [
    {"profile", "Profile default"},
    {"work_hours_30", "Every 30 minutes during work hours"},
    {"hourly", "Hourly"},
    {"daily", "Daily"},
    {"weekdays", "Weekdays"},
    {"weekly", "Weekly"},
    {"custom", "Custom"}
  ]
  @cron %{
    "work_hours_30" => "*/30 9-18 * * 1-5",
    "hourly" => "@hourly",
    "daily" => "@daily",
    "weekdays" => "0 9 * * 1-5",
    "weekly" => "@weekly"
  }

  @archetypes [
    %{
      id: "caretaker",
      profile: :caretaker,
      title: "Fleet caretaker",
      repo: false,
      description: "Recommended first agent. Operates the fleet and powers the Custode surface."
    },
    %{
      id: "backlog_worker",
      profile: :backlog_worker,
      title: "Repository backlog worker",
      repo: true,
      description: "Takes well-specified work from one repository."
    },
    %{
      id: "steward",
      profile: :steward,
      title: "Repository steward",
      repo: true,
      description: "Inspects repository health and proposes maintenance."
    },
    %{
      id: "specialist",
      profile: :specialist,
      title: "Specialist",
      repo: :optional,
      description: "Uses a high-capacity model for difficult persistent work."
    },
    %{
      id: "tutor",
      profile: :tutor,
      title: "Tutor or topic agent",
      repo: false,
      description: "Keeps context for persistent learning or non-software work."
    },
    %{
      id: "bespoke",
      profile: nil,
      title: "Bespoke agent",
      repo: :optional,
      description: "Starts from a standing prompt with no profile."
    }
  ]

  def fields, do: @fields
  def profiles, do: Routine.profiles() |> Map.keys() |> Enum.sort()
  def archetypes, do: @archetypes
  def cadences, do: @cadences
  def timezone, do: Application.get_env(:custode, :timezone, "Etc/UTC")

  def defaults(kind) when is_binary(kind) do
    case Enum.find(@archetypes, &(&1.id == kind)) do
      nil -> %{"kind" => "bespoke", "provider" => "claude", "cadence" => "profile"}
      shape -> defaults_for(shape)
    end
  end

  def repository_kind?(params) do
    case archetype(params) do
      %{repo: true} -> true
      %{repo: :optional} -> String.trim(params["repo"] || "") != ""
      _shape -> false
    end
  end

  def repository_available?(params), do: archetype(params).repo != false

  def standing_prompt_available?(params) do
    archetype(params).id in ~w(specialist tutor bespoke)
  end

  def profile_cadence(params) do
    with profile when is_binary(profile) <- blank_to_nil(params["profile"]),
         atom <- known_profile!(profile),
         cron when is_binary(cron) <- get_in(Routine.profiles(), [atom, :cron]) do
      human_cadence(cron)
    else
      _none -> "No profile schedule"
    end
  rescue
    ArgumentError -> "Unknown profile"
  end

  def plan(params) do
    with {:ok, attrs} <- attrs(params),
         {:ok, effect} <- checkout_effect(params, attrs),
         {:ok, normalized} <- normalize(attrs) do
      {:ok,
       %{
         attrs: attrs,
         toml: WriteBack.render_routine(attrs),
         effect: effect,
         resolved:
           Map.take(normalized, [
             :provider,
             :role,
             :model,
             :effort,
             :cron,
             :max_turns,
             :timeout_ms,
             :max_budget_usd,
             :daily_budget_usd,
             :daily_budget_tokens
           ])
       }}
    end
  end

  def attrs(params) do
    with {:ok, id} <- required(params, "id"),
         {:ok, cron} <- cadence(params),
         {:ok, profile} <- profile(params),
         {:ok, provider} <- provider(params["provider"] || default_provider(params)),
         :ok <- require_assignment(params, profile),
         :ok <- validate_model(provider || :claude, blank_to_nil(params["model"])) do
      attrs =
        %{id: id}
        |> optional(:provider, provider)
        |> optional(:profile, profile)
        |> optional(:cron, cron)
        |> put(params, "repo")
        |> put(params, "working_dir")
        |> put(params, "prompt")
        |> put(params, "model")
        |> put(params, "effort")
        |> put(params, "tags", &tags/1)

      checkout_attrs(params, attrs)
    end
  end

  def preview(params) do
    with {:ok, attrs} <- attrs(params), do: {:ok, WriteBack.render_routine(attrs)}
  end

  def create(params, opts \\ []) do
    if is_nil(params["kind"]), do: create_legacy(params, opts), else: create_planned(params, opts)
  end

  defp create_legacy(params, opts) do
    with {:ok, attrs} <- attrs(params), do: write(attrs, opts)
  end

  defp create_planned(params, opts) do
    with {:ok, plan} <- plan(params),
         :ok <- provision_if_managed(params, plan.attrs),
         do: write(plan.attrs, opts)
  end

  defp write(attrs, opts) do
    with {:ok, path} <- WriteBack.add_routine(attrs) do
      Custode.Feed.record(%{
        event: "repo_verb",
        agent: attrs.id,
        summary:
          "add_routine #{attrs.id}: created from the " <>
            "#{Keyword.get(opts, :surface, "dashboard")}, appended to #{path}"
      })

      {:ok, attrs.id}
    end
  end

  defp defaults_for(shape) do
    base = %{
      "kind" => shape.id,
      "provider" => "claude",
      "profile" => if(shape.profile, do: to_string(shape.profile), else: ""),
      "cadence" => if(shape.profile, do: "profile", else: "daily")
    }

    base = if shape.id == "caretaker", do: Map.put(base, "id", "custode"), else: base
    base = if shape.id == "specialist", do: Map.put(base, "id", "specialist"), else: base
    if shape.repo == true, do: Map.put(base, "checkout_mode", "managed"), else: base
  end

  defp archetype(params) do
    kind = params["kind"] || params["profile"] || "bespoke"
    Enum.find(@archetypes, List.last(@archetypes), &(&1.id == kind))
  end

  defp checkout_attrs(%{"kind" => kind} = params, %{repo: _repo} = attrs)
       when is_binary(kind),
       do: checkout_attrs_for_repo(checkout_mode(params), params, attrs)

  defp checkout_attrs(%{"kind" => kind}, attrs) when is_binary(kind),
    do: {:ok, Map.delete(attrs, :working_dir)}

  defp checkout_attrs(_legacy_params, attrs), do: {:ok, attrs}

  defp checkout_attrs_for_repo("managed", _params, attrs) do
    with {:ok, path} <- OwnedCheckout.path(attrs.id),
         do: {:ok, Map.put(attrs, :working_dir, path)}
  end

  defp checkout_attrs_for_repo(_existing, params, attrs) do
    with {:ok, path} <- required(params, "working_dir"),
         :ok <- existing_checkout(path, attrs.repo) do
      {:ok, Map.put(attrs, :working_dir, Path.expand(path))}
    end
  end

  defp checkout_effect(params, %{repo: repo, working_dir: path}) do
    case checkout_mode(params) do
      "managed" ->
        {:ok, "Clone #{repo} into #{path} on the Custode host before adding the agent."}

      _existing ->
        {:ok, "Use the existing checkout at #{path} on the Custode host."}
    end
  end

  defp checkout_effect(_params, _attrs), do: {:ok, nil}

  defp provision_if_managed(params, %{id: id, repo: repo}) do
    if checkout_mode(params) == "managed" do
      case ProvisionOwnedCheckout.dispatch(id, repo,
             actor: %{kind: :operator, id: "operator"},
             transport: :liveview,
             idempotency_key: Ecto.UUID.generate()
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:checkout_provision_failed, reason}}
      end
    else
      :ok
    end
  end

  defp provision_if_managed(_params, _attrs), do: :ok

  defp checkout_mode(%{"kind" => kind} = params) when is_binary(kind),
    do: params["checkout_mode"] || "managed"

  defp checkout_mode(params), do: params["checkout_mode"]

  defp existing_checkout(path, repo) do
    if Path.type(path) == :absolute,
      do: inspect_existing(path, repo),
      else: {:error, "working_dir must be an absolute path on the Custode host"}
  end

  defp inspect_existing(path, repo) do
    case OwnedCheckout.inspect_destination(path, repo) do
      {:ok, %{state: :matching}} ->
        :ok

      {:ok, %{state: :missing}} ->
        {:error, "working_dir does not exist on the Custode host"}

      {:ok, %{state: :empty}} ->
        {:error, "working_dir is empty, not a checkout of #{repo}"}

      {:ok, %{state: :mismatched, observed_repo: observed}} ->
        {:error, "working_dir is #{observed || "another repository"}, not #{repo}"}

      {:ok, %{state: :occupied}} ->
        {:error, "working_dir is not a Git checkout"}

      {:error, reason} ->
        {:error, "cannot inspect working_dir: #{inspect(reason)}"}
    end
  end

  defp require_assignment(%{"kind" => kind} = params, profile) when is_binary(kind) do
    shape = archetype(params)
    repo = blank_to_nil(params["repo"])
    prompt = blank_to_nil(params["prompt"])

    with :ok <- require_repository(shape, repo),
         do: require_standing_prompt(shape, prompt, profile)
  end

  defp require_assignment(_legacy_params, _profile), do: :ok

  defp require_repository(%{repo: true}, nil),
    do: {:error, "repository is required for this agent"}

  defp require_repository(_shape, _repo), do: :ok

  defp require_standing_prompt(%{id: "bespoke"}, nil, nil),
    do: {:error, "a standing prompt is required for a bespoke agent"}

  defp require_standing_prompt(%{id: "tutor"}, nil, _profile),
    do: {:error, "describe the topic or subject this agent should keep"}

  defp require_standing_prompt(_shape, _prompt, _profile), do: :ok

  defp cadence(params) do
    case params["cadence"] do
      nil ->
        legacy_cadence(params["cron"])

      "profile" ->
        {:ok, nil}

      "custom" ->
        validate_cron(params["cron"])

      preset ->
        case Map.fetch(@cron, preset) do
          {:ok, cron} -> {:ok, cron}
          :error -> {:error, "unknown cadence"}
        end
    end
  end

  defp legacy_cadence(nil), do: {:ok, nil}
  defp legacy_cadence(""), do: {:ok, nil}
  defp legacy_cadence(cron), do: validate_cron(cron)

  defp validate_cron(value) do
    with {:ok, cron} <- required(%{"cron" => value}, "cron"),
         {:ok, _expression} <- Expression.parse(cron) do
      {:ok, cron}
    else
      {:error, "cron is required"} -> {:error, "custom cron is required"}
      _invalid -> {:error, "custom cron is not valid"}
    end
  end

  defp normalize(attrs) do
    {:ok, Routine.normalize_entry(attrs)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp validate_model(_provider, nil), do: :ok
  defp validate_model(:claude, model) when model in ["opus", "sonnet", "haiku"], do: :ok
  defp validate_model(:codex, "gpt-5.6-sol"), do: :ok

  defp validate_model(provider, model),
    do: {:error, "model #{model} is not configured for #{provider}"}

  defp profile(params) do
    case blank_to_nil(params["profile"]) do
      nil -> {:ok, nil}
      value -> {:ok, known_profile!(value)}
    end
  rescue
    ArgumentError -> {:error, "unknown profile #{inspect(params["profile"])}"}
  end

  defp known_profile!(value) do
    atom = String.to_existing_atom(value)
    if Map.has_key?(Routine.profiles(), atom), do: atom, else: raise(ArgumentError)
  end

  defp provider(value) when value in ["claude", "codex"],
    do: {:ok, String.to_existing_atom(value)}

  defp provider(nil), do: {:ok, nil}
  defp provider(value), do: {:error, "unknown provider #{inspect(value)}"}

  defp default_provider(%{"kind" => kind}) when is_binary(kind), do: "claude"
  defp default_provider(_params), do: nil

  defp required(params, key) do
    case blank_to_nil(params[key]) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp tags(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  defp put(attrs, params, key, convert \\ & &1) do
    case blank_to_nil(params[key]) do
      nil -> attrs
      value -> Map.put(attrs, String.to_existing_atom(key), convert.(value))
    end
  end

  defp optional(attrs, _key, nil), do: attrs
  defp optional(attrs, key, value), do: Map.put(attrs, key, value)
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do:
      case(String.trim(value),
        do: (
          "" -> nil
          trimmed -> trimmed
        )
      )

  defp human_cadence("@daily"), do: "Daily"
  defp human_cadence("@hourly"), do: "Hourly"
  defp human_cadence("@weekly"), do: "Weekly"
  defp human_cadence("0 9 * * 1-5"), do: "Weekdays at 9:00"
  defp human_cadence(cron), do: cron
end
