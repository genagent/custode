defmodule Custode.ClaudeManagedSettingsTest do
  # Managed Claude Code settings that drop custode's --allowed-tools or block
  # bypass_permissions (#695). Every case reads fixture directories, never the
  # real ~/.claude or system policy. Not async: one case sets CLAUDE_CONFIG_DIR.
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1]

  alias Custode.ClaudeManagedSettings, as: Managed

  @tools ["mcp__custode__recall", "mcp__custode__remember", "mcp__custode__repo_list_prs"]

  setup do
    root = Path.join(System.tmp_dir!(), uid("claude-managed"))
    dirs = %{config_dir: Path.join(root, "config"), system_dir: Path.join(root, "system")}
    File.mkdir_p!(dirs.config_dir)
    File.mkdir_p!(Path.join(dirs.system_dir, "managed-settings.d"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{dirs: dirs}
  end

  defp remote!(dirs, settings),
    do: write!(Path.join(dirs.config_dir, "remote-settings.json"), settings)

  defp file!(dirs, settings),
    do: write!(Path.join(dirs.system_dir, "managed-settings.json"), settings)

  defp drop_in!(dirs, name, settings),
    do: write!(Path.join([dirs.system_dir, "managed-settings.d", name]), settings)

  defp write!(path, settings) when is_map(settings),
    do: File.write!(path, Jason.encode!(settings))

  defp write!(path, raw), do: File.write!(path, raw)

  defp policy(dirs), do: dirs |> Map.to_list() |> Managed.read() |> Managed.policy()

  defp rules_only(allow),
    do: %{"allowManagedPermissionRulesOnly" => true, "permissions" => %{"allow" => allow}}

  test "no managed source is an answer, not a warning", %{dirs: dirs} do
    policy = policy(dirs)

    assert policy.applied == []
    assert Managed.describe_permission_rules(policy, @tools) == "no managed settings found"
    assert Managed.describe_bypass(policy) == "no managed settings found"
  end

  test "rules-only with no custode allow rule warns and names the fix", %{dirs: dirs} do
    remote!(dirs, rules_only(["Read(./docs/**)"]))
    policy = policy(dirs)

    assert Managed.uncovered(policy, @tools) == @tools
    line = Managed.describe_permission_rules(policy, @tools)
    assert line =~ "warning: server-managed settings"
    assert line =~ "no managed allow rule matches the custode MCP server"
    assert line =~ "mcp__custode__*"
  end

  test "a server-wide allow rule covers every custode tool", %{dirs: dirs} do
    for rule <- ["mcp__custode__*", "mcp__custode"] do
      remote!(dirs, rules_only([rule]))
      policy = policy(dirs)

      assert Managed.uncovered(policy, @tools) == []
      refute Managed.describe_permission_rules(policy, @tools) =~ "warning"
      assert Managed.describe_permission_rules(policy, @tools) =~ "cover all 3 custode tools"
    end
  end

  test "exact and prefixed rules cover only what they name", %{dirs: dirs} do
    remote!(dirs, rules_only(["mcp__custode__recall", "mcp__custode__repo_*"]))
    policy = policy(dirs)

    assert Managed.uncovered(policy, @tools) == ["mcp__custode__remember"]

    assert Managed.describe_permission_rules(policy, @tools) =~
             "cover 2 of 3 custode tools (not remember)"
  end

  test "rules Claude Code skips allow nothing", %{dirs: dirs} do
    remote!(dirs, rules_only(["mcp__*", "*", "mcp__cust*", "mcp__custode__recall(x)", 7]))

    assert Managed.uncovered(policy(dirs), @tools) == @tools
  end

  test "disabling bypass permissions mode warns", %{dirs: dirs} do
    file!(dirs, %{"permissions" => %{"disableBypassPermissionsMode" => "disable"}})
    policy = policy(dirs)

    assert Managed.describe_bypass(policy) =~ "warning: managed settings files"
    assert Managed.describe_bypass(policy) =~ "bypass_permissions"
    assert Managed.describe_permission_rules(policy, @tools) =~ "does not set"
  end

  test "first-wins: the highest-ranked source with a policy key hides the rest", %{dirs: dirs} do
    remote!(dirs, %{"model" => "opus"})

    file!(
      dirs,
      Map.put(rules_only([]), "permissions", %{"disableBypassPermissionsMode" => "disable"})
    )

    policy = policy(dirs)

    assert [remote] = policy.applied
    assert remote =~ "remote-settings.json"
    assert policy.rules_only_by == []
    assert policy.bypass_disabled_by == []
  end

  test "a source with only control keys delivers no policy", %{dirs: dirs} do
    remote!(dirs, %{"$schema" => "https://json.schemastore.org/claude-code-settings.json"})
    file!(dirs, rules_only([]))

    assert [files] = policy(dirs).applied
    assert files =~ "managed settings files"
  end

  test "merge: lists union across sources and locks take the strictest", %{dirs: dirs} do
    remote!(dirs, %{
      "managedSourcesBehavior" => "merge",
      "permissions" => %{"allow" => ["mcp__custode__*"]}
    })

    file!(dirs, rules_only([]))
    policy = policy(dirs)

    assert length(policy.applied) == 2
    assert [_files] = policy.rules_only_by
    assert Managed.uncovered(policy, @tools) == []
  end

  test "a lower source cannot opt itself into merging", %{dirs: dirs} do
    remote!(dirs, %{"model" => "opus"})
    file!(dirs, Map.put(rules_only([]), "managedSourcesBehavior", "merge"))

    assert policy(dirs).rules_only_by == []
  end

  test "drop-ins merge after managed-settings.json in alphabetical order", %{dirs: dirs} do
    file!(dirs, rules_only(["mcp__custode__recall"]))
    # written out of order: the later name must win, not the later write
    drop_in!(dirs, "20-later.json", %{"allowManagedPermissionRulesOnly" => false})
    drop_in!(dirs, "10-earlier.json", rules_only(["mcp__custode__remember"]))

    drop_in!(dirs, ".hidden.json", %{
      "permissions" => %{"disableBypassPermissionsMode" => "disable"}
    })

    drop_in!(dirs, "notes.txt", "not settings")
    policy = policy(dirs)

    assert policy.rules_only_by == []
    assert Enum.sort(policy.allow) == ["mcp__custode__recall", "mcp__custode__remember"]
    assert policy.bypass_disabled_by == []
    assert policy.errors == []
  end

  test "an unreadable source is reported and the rest still read", %{dirs: dirs} do
    remote!(dirs, "{not json")
    file!(dirs, %{"permissions" => %{"disableBypassPermissionsMode" => "disable"}})
    policy = policy(dirs)

    assert [error] = policy.errors
    assert error =~ "remote-settings.json is not valid JSON"
    assert Managed.describe_bypass(policy) =~ "not valid JSON"
    assert [_files] = policy.bypass_disabled_by
  end

  test "the remote cache is read from CLAUDE_CONFIG_DIR", %{dirs: dirs} do
    previous = System.get_env("CLAUDE_CONFIG_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("CLAUDE_CONFIG_DIR", previous),
        else: System.delete_env("CLAUDE_CONFIG_DIR")
    end)

    System.put_env("CLAUDE_CONFIG_DIR", dirs.config_dir)
    remote!(dirs, rules_only([]))

    policy = [system_dir: dirs.system_dir] |> Managed.read() |> Managed.policy()
    assert [remote] = policy.rules_only_by
    assert remote =~ dirs.config_dir
  end
end
