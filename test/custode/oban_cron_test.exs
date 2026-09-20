defmodule Custode.ObanCronTest do
  use ExUnit.Case, async: true

  # #435: a cron insert landing between a test's snapshot and its assertion
  # changed an unfiltered Oban.Job count. The test env runs without the plugin.
  test "the running Oban has no Cron plugin in the test env" do
    plugins =
      Enum.map(Oban.config().plugins, fn
        {module, _opts} -> module
        module -> module
      end)

    # Oban reports a plugin under its resolved module name, so match on the
    # name and not on the alias the config was written with
    names = Enum.map(plugins, &(&1 |> Module.split() |> List.last()))

    refute "Cron" in names
    # the ones that keep the jobs table honest are still there
    assert "Lifeline" in names
    assert "Pruner" in names
  end
end
