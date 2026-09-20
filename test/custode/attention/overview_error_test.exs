defmodule Custode.Attention.OverviewErrorTest do
  @moduledoc """
  The gatherer's half of #485: an overview GitHub would not serve is no data,
  and no data raises no red-main or red-check signal. Before #485 the fetch
  failure never reached a reader (`:loading` forever); now it arrives as
  `{:error, reason}`, and a gatherer without a clause for it would take every
  attention surface down with a `CaseClauseError`.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Attention.Fleet
  alias Custode.GitHub.Cache

  setup do
    Custode.PubSubBridge.subscribe()

    repo = "acme/" <> uid("refused")
    on_exit(fn -> Cache.forget(repo) end)

    overviews = Application.get_env(:custode, :fake_repo_overviews, %{})
    put_env!(:fake_repo_overviews, Map.put(overviews, repo, {:error, %GhEx.Error{status: 403}}))

    %{repo: repo, routine: routine_fixture!(tmp_workspace!(), %{repo: repo})}
  end

  @tag :capture_log
  test "an agent whose repository GitHub refuses resolves as it does before the first fetch",
       %{repo: repo, routine: routine} do
    before_fetch = Map.fetch!(Fleet.signals_by_id(), routine.id)

    assert_receive {:repo_overview, ^repo}, 2_000
    assert Custode.GitHub.overview(repo) == {:error, "HTTP 403"}

    refused = Map.fetch!(Fleet.signals_by_id(), routine.id)

    assert refused.kind == before_fetch.kind
    assert refused.group == before_fetch.group
    refute refused.kind in [:red_main, :red_check, :disowned_check]

    # the ranked list is what the chip, the inbox and the CLI read
    assert Enum.any?(Fleet.signals(), &(&1.subject == routine.id))
  end
end
