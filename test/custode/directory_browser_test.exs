defmodule Custode.Operator.DirectoryBrowserTest do
  use ExUnit.Case, async: false

  alias Custode.Operator.DirectoryBrowser

  test "lists only real directories beneath configured host roots" do
    root = Path.join(System.tmp_dir!(), "custode-browser-#{System.unique_integer([:positive])}")
    child = Path.join(root, "checkout")
    File.mkdir_p!(child)
    File.write!(Path.join(root, "file.txt"), "not a directory")

    previous = Application.get_env(:custode, :checkout_roots)
    Application.put_env(:custode, :checkout_roots, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:custode, :checkout_roots, previous)
    end)

    assert {:ok, browser} = DirectoryBrowser.list(root)
    assert child in browser.directories
    refute Path.join(root, "file.txt") in browser.directories
    assert {:error, :outside_configured_roots} = DirectoryBrowser.list(System.tmp_dir!())
  end
end
