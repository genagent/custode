defmodule Custode.Config.WriteBackTest do
  # Config write-back (design 001 slice 2). Uses CUSTODE_CONFIG scoped to a
  # tmp path so no test touches a real roster file; env roster is saved and
  # restored around each test.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Config.{Loader, WriteBack}

  setup do
    path = Path.join(System.tmp_dir!(), uid("roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", path)
    previous_routines = Application.get_env(:custode, :routines)
    previous_sensors = Application.get_env(:custode, :sensors)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(path)
      Application.put_env(:custode, :routines, previous_routines)
      Application.put_env(:custode, :sensors, previous_sensors)
    end)

    %{path: path}
  end

  defp entry(id) do
    %{
      id: id,
      profile: :backlog_worker,
      repo: "example/#{id}",
      working_dir: "/tmp/#{id}",
      tags: [:rust, :external]
    }
  end

  test "write-back then reload round-trips the entry through the real loader", %{path: path} do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "existing", cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    Application.put_env(:custode, :sensors, [])

    # CUSTODE_CONFIG points at a nonexistent path -- file_path/0 raises for
    # that, so the first write-back must not consult it before creating. Use
    # the create-then-append path by touching nothing: add_routine creates
    # the file from the LIVE roster (the existing routine) plus the append.
    assert {:ok, ^path} = WriteBack.add_routine(entry("newbie"))

    # the file now exists, carries BOTH routines, and the env was reloaded
    assert File.exists?(path)
    {:ok, ^path, routines, _sensors} = Loader.load()
    assert Enum.map(routines, & &1.id) == ["existing", "newbie"]

    # the running roster picked it up in the same operation (no restart)
    assert Custode.Routine.get("newbie").role == :backlog_worker
    assert Custode.Routine.get("existing")
  end

  test "renders the literal section a gate card would show" do
    text = WriteBack.render_routine(entry("shown"))
    assert text =~ ~s([[routines]])
    assert text =~ ~s(id = "shown")
    assert text =~ ~s(profile = "backlog_worker")
    assert text =~ ~s(tags = ["rust", "external"])
    # and the rendered text is valid TOML the loader accepts
    {[parsed], []} = Loader.parse!(text)
    assert parsed.id == "shown"
    assert parsed.profile == :backlog_worker
  end

  test "duplicate ids and broken entries are refused as values" do
    workspace = tmp_workspace!()

    Application.put_env(:custode, :routines, [
      %{id: "taken", cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    assert {:error, {:duplicate_id, "taken"}} = WriteBack.add_routine(entry("taken"))
    assert {:error, :missing_id} = WriteBack.add_routine(%{profile: :backlog_worker})

    # an entry normalize rejects (no cron and no profile to supply one)
    assert {:error, {:invalid_entry, _msg}} = WriteBack.add_routine(%{id: "broken"})
  end
end
