defmodule Custode.HostTest do
  # :persistent_term is global, so this cannot interleave with the LiveView
  # tests that read it
  use ExUnit.Case, async: false

  alias Custode.Attention
  alias Custode.Host
  alias Custode.Signal

  @at ~U[2026-09-14 19:15:49.000000Z]
  @report ~s(claude auth: %{"loggedIn" => false})

  setup do
    Host.reset()
    on_exit(&Host.reset/0)
  end

  describe "doctor/0" do
    test "is :unknown until a probe has reported, which is not the same as ok" do
      assert Host.doctor() == :unknown
    end

    test "holds a pass and a failure with when they happened" do
      Host.put_doctor(:ok, @at)
      assert Host.doctor() == {:ok, @at}

      Host.put_doctor({:failed, @report}, @at)
      assert Host.doctor() == {:failed, @report, @at}
    end
  end

  describe "Attention.host/1" do
    test "a failed doctor is the most urgent thing the operator owes" do
      signal = Attention.host(%{doctor: {:failed, @report, @at}})

      assert %Signal{kind: :host_down, group: :needs_you, urgency: :high} = signal
      assert signal.subject == "custode"
      assert signal.raised_at == @at
      assert Signal.needs_you?(signal)
      assert hd(Attention.kinds()) == :host_down
    end

    test "the detail carries the failed check and what to do about it" do
      signal = Attention.host(%{doctor: {:failed, @report, @at}})

      assert signal.detail =~ "loggedIn"
      assert signal.detail =~ "Ticks are withheld"
      assert signal.detail =~ "restart"
    end

    test "it offers no buttons, because nothing in the running node clears it" do
      assert Attention.host(%{doctor: {:failed, @report, @at}}).resolving == []
    end

    test "a pass and an unknown are both silent" do
      assert Attention.host(%{doctor: {:ok, @at}}) == nil
      assert Attention.host(%{doctor: :unknown}) == nil
    end

    test "it outranks an open approval" do
      approval = %Signal{
        subject: "redis-tower",
        kind: :approval,
        group: :needs_you,
        urgency: :high,
        headline: "needs approval",
        raised_at: ~U[2026-09-01 00:00:00.000000Z]
      }

      host = Attention.host(%{doctor: {:failed, @report, @at}})

      assert [%Signal{kind: :host_down}, %Signal{kind: :approval}] =
               Attention.rank([approval, host])
    end
  end

  describe "Attention.Fleet.signals/0" do
    test "leads with the host signal while the doctor is failed, and drops it after" do
      Host.put_doctor({:failed, @report}, @at)
      assert [%Signal{kind: :host_down} | _rest] = Attention.Fleet.signals()

      Host.put_doctor(:ok, @at)
      refute Enum.any?(Attention.Fleet.signals(), &(&1.kind == :host_down))
    end

    test "signals_by_id stays per-agent" do
      Host.put_doctor({:failed, @report}, @at)

      refute Enum.any?(
               Map.values(Attention.Fleet.signals_by_id()),
               &(&1.kind == :host_down)
             )
    end
  end
end
