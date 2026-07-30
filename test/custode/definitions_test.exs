defmodule Custode.DefinitionsTest do
  # The declarative loader (#270): the authority boundary, precedence and
  # merge behavior, reference and cycle validation, and the read-only
  # compatibility adapter.
  use ExUnit.Case, async: false

  alias Custode.Definitions

  setup do
    previous = Application.get_env(:custode, :definitions)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:custode, :definitions, previous),
        else: Application.delete_env(:custode, :definitions)
    end)

    Application.delete_env(:custode, :definitions)
    :ok
  end

  describe "the authority boundary" do
    test "no surface is owned by both configuration and the database" do
      # the acceptance criterion, checked as data rather than trusted
      overlap =
        MapSet.intersection(
          MapSet.new(Definitions.configuration_owned()),
          MapSet.new(Definitions.database_owned())
        )

      assert MapSet.size(overlap) == 0
    end

    test "authority/1 answers for both owners and admits when it does not know" do
      assert Definitions.authority(:role_template) == :configuration
      assert Definitions.authority(:provider_profile) == :configuration
      assert Definitions.authority(:mission) == :database
      assert Definitions.authority(:work_item) == :database
      assert Definitions.authority(:role_binding) == :database
      assert Definitions.authority(:something_else) == :unknown
    end

    test "configuration reaching for a database-owned surface refuses to load" do
      # silently ignoring it would leave two plausible owners for one field
      assert {:error, problems} =
               Definitions.load(
                 overrides: %{"role:caretaker" => %{mission: %{"id" => "mission-1"}}}
               )

      assert [%{definition: "role:caretaker", problem: problem}] = problems
      assert problem =~ "owned by the database"
    end

    test "a runtime record cannot acquire a writable configuration twin" do
      for surface <- [:mission, :role_binding, :work_item, :attempt, :gate] do
        assert {:error, [%{problem: problem}]} =
                 Definitions.load(overrides: %{"anything" => %{surface => %{}}})

        assert problem =~ "owned by the database"
      end
    end
  end

  describe "precedence and merge" do
    test "the packaged default loads with no overrides at all" do
      assert {:ok, definitions} = Definitions.load(overrides: %{})

      assert map_size(definitions.role_templates) > 0
      assert definitions.version =~ ~r/^sha256:[0-9a-f]{64}$/
      assert definitions.bootstrap == %{}
    end

    test "an override replaces only the fields it names" do
      key = "role:caretaker"
      assert {:ok, base} = Definitions.load(overrides: %{})
      original = Map.fetch!(base.role_templates, key)

      assert {:ok, loaded} =
               Definitions.load(
                 overrides: %{key => %{budget_defaults: %{"max_budget_usd" => 9.5}}}
               )

      overridden = Map.fetch!(loaded.role_templates, key)

      assert overridden.budget_defaults == %{"max_budget_usd" => 9.5}
      # everything not named is untouched
      assert overridden.role == original.role
      assert overridden.prompt_assets == original.prompt_assets
    end

    test "extends inherits and the child still wins" do
      assert {:ok, loaded} =
               Definitions.load(
                 overrides: %{
                   "role:caretaker" => %{budget_defaults: %{"a" => 1, "b" => 2}},
                   "role:reviewer" => %{
                     extends: "role:caretaker",
                     budget_defaults: %{"b" => 99}
                   }
                 }
               )

      assert Map.fetch!(loaded.role_templates, "role:reviewer").budget_defaults == %{"b" => 99}

      assert Map.fetch!(loaded.role_templates, "role:caretaker").budget_defaults == %{
               "a" => 1,
               "b" => 2
             }
    end

    test "the version moves when the resolved content moves" do
      assert {:ok, first} = Definitions.load(overrides: %{})

      assert {:ok, second} =
               Definitions.load(overrides: %{"role:caretaker" => %{budget_defaults: %{"x" => 1}}})

      refute first.version == second.version

      # and is stable for identical input
      assert {:ok, again} = Definitions.load(overrides: %{})
      assert first.version == again.version
    end
  end

  describe "reference validation" do
    test "a cyclic extends chain fails instead of recursing forever" do
      assert {:error, [%{problem: problem}]} =
               Definitions.load(
                 overrides: %{
                   "a" => %{extends: "b"},
                   "b" => %{extends: "a"}
                 }
               )

      assert problem =~ "cycle"
    end

    test "extending something that does not exist names both halves" do
      assert {:error, [%{definition: definition, problem: problem}]} =
               Definitions.load(overrides: %{"a" => %{extends: "nowhere"}})

      # the definition at fault, and the thing it wanted
      assert definition == "a"
      assert problem =~ "unknown definition nowhere"
    end

    test "a prompt asset that does not resolve fails before work is scheduled" do
      assert {:error, problems} =
               Definitions.load(
                 overrides: %{
                   "role:caretaker" => %{
                     prompt_assets: [%{"kind" => "packaged_asset", "id" => "no-such-asset"}]
                   }
                 }
               )

      assert Enum.any?(problems, &(&1.problem =~ "no-such-asset does not resolve"))
    end

    test "a declared verification recipe must exist" do
      assert {:error, problems} =
               Definitions.load(
                 overrides: %{
                   "role:caretaker" => %{
                     recipe: %{"kind" => "verification", "name" => "nope", "version" => "1"}
                   }
                 }
               )

      assert Enum.any?(problems, &(&1.problem =~ "unknown verification recipe nope"))
    end

    test "a real verification recipe passes" do
      assert {:ok, _loaded} =
               Definitions.load(
                 overrides: %{
                   "role:caretaker" => %{
                     recipe: %{
                       "kind" => "verification",
                       "name" => "elixir_repository",
                       "version" => "1"
                     }
                   }
                 }
               )
    end

    test "a bootstrap declaration naming an unknown provider profile fails" do
      assert {:error, problems} =
               Definitions.load(
                 overrides: %{
                   "bootstrap" => %{"fleet" => %{"provider_profile" => "not_a_profile"}}
                 }
               )

      assert Enum.any?(problems, &(&1.problem =~ "unknown provider profile not_a_profile"))
    end

    test "verify/0 is load/1 without the payload" do
      assert Definitions.verify(overrides: %{}) == :ok
      assert {:error, _problems} = Definitions.verify(overrides: %{"a" => %{extends: "a"}})
    end
  end

  test "the routine compatibility view is marked read-only and names its source" do
    view = Definitions.for_routine(%{id: "custode-dev", role: :repo_caretaker})

    assert view.source.kind == "legacy_routine"
    assert view.source.id == "custode-dev"
    # configuration is only ever read, so nothing offers to write it back
    refute view.source.writable
    assert view.version =~ ~r/^sha256:/
    assert is_map(view.executor_defaults)
  end

  test "report never raises, whatever it finds" do
    assert Definitions.report() == :ok

    Application.put_env(:custode, :definitions, %{"a" => %{extends: "a"}})
    assert Definitions.report() == :ok
  end
end
