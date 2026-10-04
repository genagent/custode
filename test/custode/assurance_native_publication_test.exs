defmodule Custode.Assurance.NativePublicationTest do
  use ExUnit.Case, async: true

  test "public proof retains decisions and bindings without native identifiers or account metrics" do
    bytes =
      File.read!(Application.app_dir(:custode, "priv/assurance_native/native-proof-results.json"))

    report = Jason.decode!(bytes)
    assert report["native_records_unchanged"]
    assert report["new_native_calls"] == 0
    assert length(report["native_calls"]) == 4
    assert length(report["failed_setup_attempts"]) == 3
    assert is_map(report["public_redaction"])
    refute bytes =~ "/Users/"
    refute bytes =~ "/private/tmp/custode-795-native"
    verify_public(report)

    assert Enum.map(report["cases"], &{&1["variant"], &1["decision"]["status"]}) ==
             [{"clean", "accepted"}, {"seeded", "rejected"}]

    for observed <- report["native_calls"] do
      assert observed["captured_record_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert observed["observed"]["session_id"] =~ ~r/\Asession-sha256:[0-9a-f]{64}\z/
    end
  end

  defp verify_public(value) when is_map(value) do
    for {key, child} <- value do
      refute key in ~w(usage cost_usd reported_cost_usd)

      if key in ~w(session_id native_session_id) and is_binary(child),
        do: assert(child =~ ~r/\Asession-sha256:[0-9a-f]{64}\z/)

      if key == "run_id" and is_binary(child), do: assert(child =~ "session-sha256:")
      verify_public(child)
    end
  end

  defp verify_public(value) when is_list(value), do: Enum.each(value, &verify_public/1)
  defp verify_public(_value), do: :ok
end
