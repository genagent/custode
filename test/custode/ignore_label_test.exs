defmodule Custode.IgnoreLabelTest do
  @moduledoc """
  Per-issue posture (#334), the half that needs no doctrine change: an
  operator can label an issue out of the fleet's survey.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  doctest Custode.Repository, only: [partition_ignored: 2]

  alias Custode.Repository

  setup do
    workspace = tmp_workspace!()
    repo = "acme/" <> uid("ign")

    put_env!(:routines, [
      %{
        id: uid("ign-agent"),
        cron: "@daily",
        workspace: workspace,
        prompt: "sweep",
        repo: repo,
        working_dir: workspace
      }
    ])

    %{repo: repo}
  end

  defp issue(number, labels), do: %{number: number, title: "i#{number}", labels: labels}

  describe "the ignore label" do
    test "defaults to custode:ignore and is configurable" do
      assert Repository.ignore_label() == "custode:ignore"

      put_env!(:ignore_label, "wontfix")
      assert Repository.ignore_label() == "wontfix"
    end
  end

  describe "filtering, as a pure decision" do
    # The tool's filter is the whole behaviour, and it is a one-liner over
    # labels the row already carries. Asserted through the shape the agent
    # actually receives.
    test "withholds a labelled issue, keeps the rest, and SAYS how many" do
      rows = [
        issue(1, []),
        issue(2, ["custode:ignore"]),
        issue(3, ["bug"])
      ]

      {kept, ignored} = split(rows, "custode:ignore")

      assert Enum.map(kept, & &1.number) == [1, 3]
      assert ignored == 1
    end

    test "an issue with several labels is still ignored if one of them says so" do
      rows = [issue(1, ["bug", "custode:ignore", "workable"])]
      {kept, ignored} = split(rows, "custode:ignore")

      assert kept == []
      assert ignored == 1
    end

    test "nothing labelled means nothing withheld" do
      rows = [issue(1, ["bug"]), issue(2, [])]
      assert {^rows, 0} = split(rows, "custode:ignore")
    end

    test "a different configured label is what counts" do
      rows = [issue(1, ["custode:ignore"]), issue(2, ["wontfix"])]
      {kept, ignored} = split(rows, "wontfix")

      assert Enum.map(kept, & &1.number) == [1]
      assert ignored == 1
    end
  end

  # Calls the real decision rather than mirroring it, so the test cannot
  # drift from the code it is about.
  defp split(rows, label) do
    {kept, ignored} = Repository.partition_ignored(rows, label)
    {kept, length(ignored)}
  end
end
