defmodule CustodeWeb.Console.CommandsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Signal
  alias CustodeWeb.Console.Commands

  setup do
    workspace = tmp_workspace!()
    id = uid("commands")
    put_env!(:routines, [%{id: id, cron: "@daily", workspace: workspace, prompt: "sweep"}])

    signal = %Signal{
      subject: id,
      kind: :needs_answer,
      group: :needs_you,
      urgency: :high,
      headline: "asked which environment"
    }

    %{id: id, signal: signal}
  end

  test "builds distinct destinations, attention, subjects, results and actions", %{
    id: id,
    signal: signal
  } do
    Custode.Feed.record(%{event: "turn", agent: id, summary: "compared both approaches"})

    commands = Commands.all([signal], id)

    assert Enum.any?(commands, &(&1.group == :subject && &1.label == id))
    assert Enum.any?(commands, &(&1.group == :attention && &1.label =~ "environment"))
    assert Enum.any?(commands, &(&1.group == :result && &1.label =~ "compared"))
    assert Enum.any?(commands, &(&1.group == :action && &1.action == :pause))
    assert Enum.any?(commands, &(&1.id == "go-manager" && &1.shortcut == "⇧⌘K"))
  end

  test "search requires every term and ranks a label prefix first", %{id: id, signal: signal} do
    commands = Commands.all([signal], id)

    assert [%{label: ^id}] = Commands.search(commands, "#{id} subject")
    assert [%{id: "action-pause"}] = Commands.search(commands, "pause #{id}")
    assert [] == Commands.search(commands, "does-not-exist")
  end

  test "only offers operations that apply to the selected subject" do
    proposal = %Signal{
      subject: "release on acme/widgets",
      kind: :gate,
      group: :needs_you,
      urgency: :high,
      headline: "wants approval",
      item: {:proposal, 42}
    }

    actions = Commands.all([proposal], proposal.subject) |> Enum.filter(&(&1.group == :action))

    assert Enum.map(actions, & &1.action) == [:new_agent]
  end
end
