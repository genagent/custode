defmodule Custode.AssetsTest do
  # Packaged prompt assets (#269, design/003 D4): the precedence chain, the
  # derived version, startup validation, and the override boot report.
  use ExUnit.Case, async: false

  alias Custode.{Assets, Routine}

  setup do
    home = Path.join(System.tmp_dir!(), "custode-assets-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(home, "prompts"))

    previous_home = System.get_env("CUSTODE_HOME")
    previous_declarations = Application.get_env(:custode, :prompt_assets)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("CUSTODE_HOME", previous_home),
        else: System.delete_env("CUSTODE_HOME")

      if previous_declarations,
        do: Application.put_env(:custode, :prompt_assets, previous_declarations),
        else: Application.delete_env(:custode, :prompt_assets)

      File.rm_rf!(home)
    end)

    Application.delete_env(:custode, :prompt_assets)
    %{home: home}
  end

  test "a release contains every referenced default asset" do
    # the acceptance criterion in the plainest form it can be asserted
    assert Assets.verify() == :ok

    for id <- Assets.prompt_ids() do
      assert {:ok, asset} = Assets.fetch(id)
      assert asset.origin == :packaged
      assert asset.content != ""
    end
  end

  test "a version is derived from the content, not declared beside it" do
    assert {:ok, asset} = Assets.fetch("caretaker")

    expected = :sha256 |> :crypto.hash(asset.content) |> Base.encode16(case: :lower)
    assert asset.digest == expected
    assert asset.version == "sha256:" <> expected
    assert asset.media_type == "text/markdown"
  end

  test "precedence is config, then the config directory, then the packaged default", %{home: home} do
    assert {:ok, packaged} = Assets.fetch("caretaker")
    assert packaged.origin == :packaged

    # 2. the operator's escape hatch
    System.put_env("CUSTODE_HOME", home)
    config_dir_file = Path.join([home, "prompts", "caretaker.md"])
    File.write!(config_dir_file, "from the config directory\n")

    assert {:ok, from_dir} = Assets.fetch("caretaker")
    assert from_dir.origin == :config_dir
    assert from_dir.path == config_dir_file
    assert from_dir.content == "from the config directory\n"

    # 1. an explicit declaration outranks it
    explicit = Path.join(home, "explicit-caretaker.md")
    File.write!(explicit, "from an explicit declaration\n")
    Application.put_env(:custode, :prompt_assets, %{"caretaker" => [path: explicit]})

    assert {:ok, from_config} = Assets.fetch("caretaker")
    assert from_config.origin == :config
    assert from_config.content == "from an explicit declaration\n"
  end

  test "an override is named rather than silently in force", %{home: home} do
    assert Assets.overrides_in_effect() == []

    System.put_env("CUSTODE_HOME", home)
    File.write!(Path.join([home, "prompts", "steward.md"]), "overridden\n")

    assert [%{id: "steward", origin: :config_dir} = override] = Assets.overrides_in_effect()

    assert override.version ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, "overridden\n"), case: :lower)

    # the boot report never raises, whatever it finds
    assert Assets.report() == :ok
  end

  test "a missing configured asset fails with the paths it searched" do
    Application.put_env(:custode, :prompt_assets, %{"caretaker" => [path: "/nonexistent/x.md"]})

    assert {:error, reason} = Assets.fetch("caretaker")
    assert {:asset_unreadable, "caretaker", "/nonexistent/x.md", :enoent} = reason

    assert {:error, [%{id: "caretaker", reason: message}]} = Assets.verify()
    assert message =~ "could not be read"
    assert message =~ "/nonexistent/x.md"
  end

  test "an unknown asset id reports every path it looked in" do
    assert {:error, {:asset_missing, "nope", searched}} = Assets.fetch("nope")
    assert Enum.any?(searched, &String.ends_with?(&1, "priv/prompts/nope.md"))
  end

  test "content that is not valid UTF-8 is rejected", %{home: home} do
    explicit = Path.join(home, "binary.md")
    File.write!(explicit, <<0xFF, 0xFE, 0x00>>)
    Application.put_env(:custode, :prompt_assets, %{"caretaker" => [path: explicit]})

    assert {:error, {:asset_not_utf8, "caretaker", ^explicit}} = Assets.fetch("caretaker")
  end

  test "a declared version that does not match the bytes is an actionable error", %{home: home} do
    explicit = Path.join(home, "declared.md")
    File.write!(explicit, "some text\n")

    Application.put_env(:custode, :prompt_assets, %{
      "caretaker" => [path: explicit, version: "sha256:not-the-real-digest"]
    })

    assert {:error, {:asset_version_mismatch, "caretaker", ^explicit, declared, actual}} =
             Assets.fetch("caretaker")

    assert declared == "sha256:not-the-real-digest"

    assert actual ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, "some text\n"), case: :lower)

    # and a declaration that DOES match is accepted
    Application.put_env(:custode, :prompt_assets, %{
      "caretaker" => [path: explicit, version: actual]
    })

    assert {:ok, %{version: ^actual}} = Assets.fetch("caretaker")
  end

  test "substitution replaces bound placeholders and leaves unbound ones visible", %{home: home} do
    explicit = Path.join(home, "template.md")
    File.write!(explicit, "routine {{routine_id}} role {{role}} unknown {{other}}\n")
    Application.put_env(:custode, :prompt_assets, %{"caretaker" => [path: explicit]})

    rendered = Assets.render!("caretaker", %{"routine_id" => "adrs", "role" => "caretaker"})

    assert rendered == "routine adrs role caretaker unknown {{other}}\n"
  end

  test "the composed charter still carries its assignment values" do
    composed = Routine.Prompts.for_role(:caretaker, "adrs")

    assert composed =~ ~s|routine_id "adrs"|
    assert composed =~ "role\ncaretaker."
    refute composed =~ "{{"
  end

  test "a role's asset references carry identity, version and hash" do
    assert [charter, role] = Routine.Prompts.assets_for_role(:caretaker)

    assert charter["id"] == "charter"
    assert charter["kind"] == "packaged_asset"
    assert charter["origin"] == "packaged"
    assert charter["version"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert charter["digest"] =~ ~r/^[0-9a-f]{64}$/

    assert role["id"] == "caretaker"
  end

  test "an unresolvable reference is explicit rather than absent" do
    assert %{"id" => "nope", "status" => "unresolved"} = Assets.reference("nope")
  end
end
