defmodule Custode.CheckoutTest do
  use ExUnit.Case, async: true

  alias Custode.Checkout

  doctest Custode.Checkout

  describe "status/1" do
    test "a directory that is not a git repository is skipped, not failed" do
      dir = Path.join(System.tmp_dir!(), "nogit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # design/003's binary target ships without a checkout at all; that is
      # a normal install, not a degraded one
      assert Checkout.status(dir) == :not_a_checkout
    end

    test "a repository with no upstream has nothing to compare" do
      dir = Path.join(System.tmp_dir!(), "bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {_out, 0} = System.cmd("git", ["init", "--quiet"], cd: dir, stderr_to_stdout: true)

      assert Checkout.status(dir) == :no_upstream
    end
  end

  describe "describe/1" do
    test "being behind says what to do about it" do
      message = Checkout.describe({:behind, 3, "2h ago"})

      assert message =~ "3 commit(s) behind"
      assert message =~ "2h ago"
      assert message =~ "git pull"
    end

    test "being current still says how fresh the comparison is" do
      # a comparison against a stale remote-tracking ref that reads as
      # reassurance is worse than no comparison at all
      assert Checkout.describe({:current, "5d ago"}) =~ "5d ago"
    end

    test "never having fetched is not reported as being up to date" do
      message = Checkout.describe({:current, :never})

      refute message =~ "up to date"
      assert message =~ "never fetched"
      assert message =~ "git pull"
    end

    test "behind with no fetch history says so rather than inventing an age" do
      assert Checkout.describe({:behind, 2, :never}) =~ "never fetched"
    end

    test "the skipped cases read as answers, not errors" do
      assert Checkout.describe(:no_upstream) =~ "nothing to compare"
      assert Checkout.describe(:not_a_checkout) == "not a git checkout"
    end
  end
end
