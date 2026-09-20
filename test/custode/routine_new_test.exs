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
end
