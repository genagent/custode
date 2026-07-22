defmodule Custode.InstanceTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Instance
  alias Custode.Instance.Row
  alias Custode.Repo

  # Each test claims its OWN key so it never races the live app instance,
  # which holds the "singleton" row and beats it for the whole run.
  setup do
    key = uid("instance")
    on_exit(fn -> Instance.purge(key) end)
    {:ok, key: key}
  end

  defp put_foreign!(key, beat_at, os_pid \\ "foreign-pid") do
    Repo.insert!(%Row{key: key, node: "nonode@nohost", os_pid: os_pid, beat_at: beat_at})
  end

  describe "claim/2" do
    test "claims a free row", %{key: key} do
      assert :ok = Instance.claim(key, os_pid: "me")
      assert %Row{os_pid: "me"} = Instance.holder(key)
    end

    test "refuses a fresh foreign heartbeat", %{key: key} do
      now = DateTime.utc_now()
      put_foreign!(key, now)

      assert {:error, {:occupied, holder}} =
               Instance.claim(key, os_pid: "me", now: now, stale_after_ms: 30_000)

      assert holder.os_pid == "foreign-pid"
      # the foreign row is left untouched -- we did NOT seize it
      assert %Row{os_pid: "foreign-pid"} = Instance.holder(key)
    end

    test "reclaims a stale foreign heartbeat", %{key: key} do
      now = DateTime.utc_now()
      stale = DateTime.add(now, -60, :second)
      put_foreign!(key, stale)

      assert :ok = Instance.claim(key, os_pid: "me", now: now, stale_after_ms: 30_000)
      assert %Row{os_pid: "me"} = Instance.holder(key)
    end

    test "reclaims our own row regardless of freshness", %{key: key} do
      now = DateTime.utc_now()
      # a fresh row we already own (same os_pid) is ours to refresh, never a conflict
      put_foreign!(key, now, "me")

      assert :ok = Instance.claim(key, os_pid: "me", now: now, stale_after_ms: 30_000)
      assert %Row{os_pid: "me"} = Instance.holder(key)
    end

    test "takeover seizes a fresh foreign heartbeat", %{key: key} do
      now = DateTime.utc_now()
      put_foreign!(key, now)

      assert :ok =
               Instance.claim(key, os_pid: "me", now: now, stale_after_ms: 30_000, takeover: true)

      assert %Row{os_pid: "me"} = Instance.holder(key)
    end
  end

  describe "the guard process (boot path)" do
    test "starts and beats when the row is free", %{key: key} do
      {:ok, pid} =
        Instance.start_link(name: nil, key: key, beat_interval_ms: 20, os_pid: "me")

      assert %Row{os_pid: "me"} = Instance.holder(key)

      first = Instance.holder(key).beat_at
      # the periodic beat advances the timestamp
      assert eventually(fn -> DateTime.compare(Instance.holder(key).beat_at, first) == :gt end)

      GenServer.stop(pid)
    end

    test "refuses to boot behind a fresh foreign instance", %{key: key} do
      put_foreign!(key, DateTime.utc_now())

      Process.flag(:trap_exit, true)

      assert {:error, {:instance_conflict, holder}} =
               Instance.start_link(name: nil, key: key, os_pid: "me", stale_after_ms: 30_000)

      assert holder.os_pid == "foreign-pid"
    end

    test "boots with takeover even behind a fresh foreign instance", %{key: key} do
      put_foreign!(key, DateTime.utc_now())

      {:ok, pid} =
        Instance.start_link(
          name: nil,
          key: key,
          os_pid: "me",
          takeover: true,
          beat_interval_ms: 60_000
        )

      assert %Row{os_pid: "me"} = Instance.holder(key)
      GenServer.stop(pid)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.find(1..attempts, fn _ ->
      Process.sleep(10)
      fun.()
    end)
  end
end
