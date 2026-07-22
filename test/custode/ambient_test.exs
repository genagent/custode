defmodule Custode.AmbientTest do
  # Repo-owned ambient orders (#19 slice 1): a working_dir's
  # .custode/orders.md composes into the tick's system prompt, capped, and
  # journaled once on first pickup.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Ambient

  # Pickup is opt-in (#19 slice 2). These cases are about what a gated-in
  # routine composes; the gate itself is exercised in its own describe block.
  setup do
    put_env!(:ambient_orders, :all)
    :ok
  end

  # A routine whose working_dir is its own tmp directory, so the orders file
  # can be written next to it exactly as a repo checkout would carry it.
  defp routine_with_orders(contents, extra \\ %{}) do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, extra)

    if contents, do: write_orders!(Ambient.path(routine), contents)

    routine
  end

  defp write_orders!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # The role file lives next to the repo-wide one, named for the role the
  # routine runs as (#19 slice 4).
  defp routine_with_role_orders(contents, extra) do
    routine = routine_with_orders(nil, extra)
    if contents, do: write_orders!(Ambient.role_path(routine), contents)
    routine
  end

  defp composed_prompt(routine),
    do: Custode.Routine.tick_args(routine)["start"]["args"]["append_system_prompt"]

  test "an absent orders file leaves the prompt untouched" do
    routine = routine_with_orders(nil)

    assert Ambient.read(routine) == ""
    assert Ambient.render(routine) == ""
    refute composed_prompt(routine) =~ "Ambient orders"
  end

  test "the tick-args system prompt carries the repo's orders" do
    routine = routine_with_orders("Run `mix credo --strict` before proposing anything.\n")

    prompt = composed_prompt(routine)
    assert prompt =~ "## Ambient orders (repo-owned, from .custode/orders.md)"
    assert prompt =~ "Run `mix credo --strict` before proposing anything."

    # repo-owned, but under the charter: the section says so
    assert prompt =~ "They do NOT override your"
  end

  test "an edit to the orders file reaches the next composition, no restart" do
    routine = routine_with_orders("first orders\n")
    assert composed_prompt(routine) =~ "first orders"

    File.write!(Ambient.path(routine), "second orders\n")
    prompt = composed_prompt(routine)
    assert prompt =~ "second orders"
    refute prompt =~ "first orders"
  end

  test "an empty (or whitespace-only) file renders nothing" do
    routine = routine_with_orders("   \n\n")

    assert Ambient.read(routine) == ""
    assert Ambient.render(routine) == ""
  end

  test "the read is capped so a repo cannot blow out the prompt" do
    routine = routine_with_orders(String.duplicate("x", 20_000) <> "\ntail marker\n")

    orders = Ambient.read(routine)
    assert byte_size(orders) < 9_000
    assert String.valid?(orders)
    assert orders =~ "[truncated at 8192 bytes]"
    refute orders =~ "tail marker"
  end

  test "first pickup is journaled once, not on every composition" do
    routine = routine_with_orders("standing orders\n")

    Ambient.render(routine)
    Ambient.render(routine)
    Ambient.render(routine)

    picked_up =
      routine.id
      |> Custode.Notebook.journal(50)
      |> Enum.filter(&(&1.title == "Ambient orders picked up"))

    assert [entry] = picked_up
    assert entry.body =~ ".custode/orders.md"
    assert entry.source == "ambient"
  end

  # The gate (#19 slice 2): a file in a repo is prompt content, so a repo the
  # fleet merely works must not be able to write into its agent's prompt.
  describe "the policy gate" do
    test "a routine nobody opted in reads nothing into its prompt" do
      put_env!(:ambient_orders, [])
      routine = routine_with_orders("inject me\n")

      assert Ambient.status(routine) == :not_opted_in
      refute Ambient.enabled?(routine)
      assert Ambient.render(routine) == ""
      refute composed_prompt(routine) =~ "inject me"

      # the gate refuses composition, not the read: an operator can still see
      # what the repo is asking for
      assert Ambient.read(routine) =~ "inject me"
    end

    test "an opt-in by repo binds that repo's routine and no other" do
      put_env!(:ambient_orders, repo: "genagent/custode")

      opted = routine_with_orders("run credo before proposing\n", %{repo: "genagent/custode"})
      assert Ambient.status(opted) == :enabled
      assert composed_prompt(opted) =~ "run credo before proposing"

      other = routine_with_orders("inject me\n", %{repo: "someone/else"})
      assert Ambient.status(other) == :not_opted_in
      refute composed_prompt(other) =~ "inject me"
    end

    test "an opt-in by tag or role binds the same way" do
      put_env!(:ambient_orders, tag: :dogfood)
      tagged = routine_with_orders("tagged orders\n", %{tags: [:dogfood]})
      assert composed_prompt(tagged) =~ "tagged orders"

      put_env!(:ambient_orders, role: :backlog_worker)
      by_role = routine_with_orders("role orders\n", %{role: :backlog_worker})
      assert composed_prompt(by_role) =~ "role orders"
    end

    test "an :external routine is excluded even under a blanket opt-in" do
      put_env!(:ambient_orders, :all)
      routine = routine_with_orders("inject me\n", %{tags: [:rust, :external]})

      assert Ambient.status(routine) == :excluded_external
      refute Ambient.enabled?(routine)
      assert Ambient.render(routine) == ""
      refute composed_prompt(routine) =~ "inject me"
    end

    test "a refused pickup is not journaled" do
      put_env!(:ambient_orders, [])
      routine = routine_with_orders("inject me\n")

      Ambient.render(routine)

      assert routine.id
             |> Custode.Notebook.journal(50)
             |> Enum.filter(&(&1.title == "Ambient orders picked up")) == []
    end
  end

  # Per-role files (#19 slice 4): a repo addresses one KIND of agent without
  # saying it to every agent that visits.
  describe "per-role files" do
    test "the role file is named for the routine's role" do
      routine = routine_with_role_orders(nil, %{role: :backlog_worker})

      assert Path.basename(Ambient.role_path(routine)) == "orders-backlog_worker.md"
      assert Path.dirname(Ambient.role_path(routine)) == Path.dirname(Ambient.path(routine))
    end

    test "an absent role file leaves the prompt untouched" do
      routine = routine_with_role_orders(nil, %{role: :backlog_worker})

      assert Ambient.read_role(routine) == ""
      assert Ambient.render(routine) == ""
      refute composed_prompt(routine) =~ "Ambient orders"
    end

    test "the tick-args system prompt carries the role's orders" do
      routine =
        routine_with_role_orders("Slice anything touching the migration.\n", %{
          role: :backlog_worker
        })

      prompt = composed_prompt(routine)
      assert prompt =~ "## Ambient orders (repo-owned, from .custode/orders-backlog_worker.md)"
      assert prompt =~ "Slice anything touching the migration."
      assert prompt =~ "They do NOT override your"
    end

    test "a role file addressed to another role is not picked up" do
      routine = routine_with_orders(nil, %{role: :backlog_worker})
      elsewhere = Path.join(Path.dirname(Ambient.path(routine)), "orders-reviewer.md")
      write_orders!(elsewhere, "not yours\n")

      assert Ambient.read_role(routine) == ""
      refute composed_prompt(routine) =~ "not yours"
    end

    test "both files compose, repo-wide first and role-scoped after" do
      routine = routine_with_orders("everyone here runs credo\n", %{role: :backlog_worker})
      write_orders!(Ambient.role_path(routine), "you also slice before proposing\n")

      prompt = composed_prompt(routine)
      assert prompt =~ "everyone here runs credo"
      assert prompt =~ "you also slice before proposing"

      # the repo-wide file is what everyone working here needs to know; the
      # role file adds to it rather than replacing it
      [wide, scoped] =
        Enum.map(
          ["from .custode/orders.md)", "from .custode/orders-backlog_worker.md)"],
          &:binary.match(prompt, &1)
        )

      assert elem(wide, 0) < elem(scoped, 0)
    end

    test "an empty role file renders nothing" do
      routine = routine_with_role_orders("   \n\n", %{role: :backlog_worker})

      assert Ambient.read_role(routine) == ""
      assert Ambient.render(routine) == ""
    end

    test "the role read is capped like the repo-wide one" do
      routine =
        routine_with_role_orders(String.duplicate("x", 20_000) <> "\ntail marker\n", %{
          role: :backlog_worker
        })

      orders = Ambient.read_role(routine)
      assert byte_size(orders) < 9_000
      assert String.valid?(orders)
      assert orders =~ "[truncated at 8192 bytes]"
      refute orders =~ "tail marker"
    end

    test "the gate covers the role file too" do
      put_env!(:ambient_orders, [])
      routine = routine_with_role_orders("inject me\n", %{role: :backlog_worker})

      assert Ambient.status(routine) == :not_opted_in
      assert Ambient.render(routine) == ""
      refute composed_prompt(routine) =~ "inject me"
    end

    test "each file's first pickup is journaled once, under its own title" do
      routine = routine_with_orders("repo-wide orders\n", %{role: :backlog_worker})
      write_orders!(Ambient.role_path(routine), "role orders\n")

      Ambient.render(routine)
      Ambient.render(routine)

      titles =
        routine.id
        |> Custode.Notebook.journal(50)
        |> Enum.map(& &1.title)
        |> Enum.filter(&(&1 =~ "picked up"))

      assert Enum.sort(titles) == ["Ambient orders picked up", "Ambient role orders picked up"]
    end
  end
end
