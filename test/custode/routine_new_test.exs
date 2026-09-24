defmodule Custode.Operator.RoutineNewTest do
  use ExUnit.Case, async: true

  alias Custode.Operator.RoutineNew

  test "an id is required, and says so" do
    assert RoutineNew.attrs(%{"id" => "  "}) == {:error, "id is required"}
  end

  test "blank fields are left out so the routine inherits them, and tags become atoms" do
    assert {:ok, attrs} =
             RoutineNew.attrs(%{
               "id" => " my-repo ",
               "repo" => "acme/widgets",
               "cron" => "",
               "tags" => "repo, rust, "
             })

    assert attrs == %{id: "my-repo", repo: "acme/widgets", tags: [:repo, :rust]}
  end

  test "an unknown profile is refused by membership, never by minting an atom" do
    assert {:error, message} =
             RoutineNew.attrs(%{"id" => "x", "profile" => "no-such-profile-ever"})

    assert message =~ "unknown profile"
  end

  test "the preview is the TOML a create would append" do
    assert {:ok, toml} = RoutineNew.preview(%{"id" => "my-repo", "cron" => "@daily"})
    assert toml =~ "[[routines]]"
    assert toml =~ ~s(id = "my-repo")
    assert toml =~ ~s(cron = "@daily")
  end

  test "cadence presets avoid cron syntax and profile default stays omitted" do
    assert {:ok, hourly} =
             RoutineNew.attrs(%{
               "id" => "hourly",
               "kind" => "caretaker",
               "provider" => "claude",
               "profile" => "caretaker",
               "cadence" => "hourly"
             })

    assert hourly.cron == "@hourly"

    assert {:ok, inherited} =
             RoutineNew.attrs(%{
               "id" => "custode",
               "kind" => "caretaker",
               "provider" => "claude",
               "profile" => "caretaker",
               "cadence" => "profile"
             })

    refute Map.has_key?(inherited, :cron)
  end

  test "specialist plan shows the provider-specific model and larger rails" do
    params = RoutineNew.defaults("specialist") |> Map.put("provider", "codex")
    assert {:ok, plan} = RoutineNew.plan(params)
    assert plan.resolved.role == :specialist
    assert plan.resolved.model == "gpt-5.6-sol"
    assert plan.resolved.effort == :high
    assert plan.resolved.max_turns == 120
    assert plan.toml =~ ~s(profile = "specialist")
  end

  test "custom cadence is validated" do
    params = %{
      "id" => "custom",
      "kind" => "caretaker",
      "provider" => "claude",
      "profile" => "caretaker",
      "cadence" => "custom",
      "cron" => "not cron"
    }

    assert RoutineNew.plan(params) == {:error, "custom cron is not valid"}
  end

  test "a managed repository plan names the deterministic host action" do
    params =
      RoutineNew.defaults("backlog_worker")
      |> Map.merge(%{"id" => "widgets", "repo" => "acme/widgets"})

    assert {:ok, plan} = RoutineNew.plan(params)
    assert plan.attrs.working_dir =~ "/checkouts/widgets"
    assert plan.effect =~ "Clone acme/widgets"
    assert plan.toml =~ ~s(working_dir = "#{plan.attrs.working_dir}")
  end
end
