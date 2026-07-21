defmodule Custode.PolicyTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  setup do
    put_env!(:policies, [
      %{id: :external_writes, applies: [tag: :external], text: "never touch external repos"},
      %{id: :no_contrib, applies: :all, text: "never engage contributors"},
      %{id: :merge, applies: [repo: "acme/thing"], value: :manual, text: "humans merge"},
      %{id: :worker_pace, applies: [role: :backlog_worker], text: "one item per sweep"}
    ])

    :ok
  end

  test "policies scope by :all, tag, repo, and role -- any selector binds" do
    workspace = tmp_workspace!()

    external =
      routine_fixture!(workspace, %{tags: [:external], repo: "acme/thing", role: :backlog_worker})

    assert Custode.Policy.ids_for(external) ==
             ~w(external_writes no_contrib merge worker_pace)

    plain = routine_fixture!(workspace)
    assert Custode.Policy.ids_for(plain) == ~w(no_contrib)
  end

  test "render/1 produces the binding section from the declarations, or nothing" do
    workspace = tmp_workspace!()
    tagged = routine_fixture!(workspace, %{tags: [:external]})

    rendered = Custode.Policy.render(tagged)
    assert rendered =~ "## Policies (binding"
    assert rendered =~ "[external_writes] never touch external repos"
    assert rendered =~ "[no_contrib]"
    refute rendered =~ "humans merge"

    put_env!(:policies, [])
    assert Custode.Policy.render(tagged) == ""
  end

  test "policies ride every composed prompt, including custom system_prompt overrides" do
    workspace = tmp_workspace!()

    custom =
      routine_fixture!(workspace, %{system_prompt: "you are a test", tags: [:external]})

    prompt = Custode.Routine.tick_args(custom)["start"]["args"]["append_system_prompt"]
    assert prompt =~ "you are a test"
    assert prompt =~ "never touch external repos"
    assert prompt =~ "never engage contributors"
  end
end
