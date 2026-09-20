defmodule Custode.BootProjectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Custode.BootProjection

  doctest Custode.BootProjection

  # the first live boot after design/010: `redis/redisctl` answered 403 behind
  # an org's SAML SSO, and the boot Task raised with the whole HTTP response
  @gh_error %{
    status: 403,
    message: "Resource protected by organization SAML enforcement.",
    headers: %{
      "x-github-sso" => [
        "required; url=https://github.com/enterprises/x/sso?authorization_request=SECRET"
      ]
    }
  }

  test "a failure is one warning naming the routine, and the run still returns :ok" do
    report = %{
      failures: [
        %{
          legacy_routine_id: "redisctl",
          reason: {:repository_identity_unavailable, "redis/redisctl", @gh_error}
        }
      ]
    }

    log =
      capture_log(fn ->
        assert :ok = BootProjection.run("legacy Mission projection", fn -> {:error, report} end)
      end)

    assert log =~ "legacy Mission projection skipped redisctl"
    assert log =~ "repository identity unavailable for redis/redisctl (HTTP 403)"
  end

  test "the response headers, which can carry an authorization URL, never reach the log" do
    report = %{
      failures: [
        %{
          legacy_routine_id: "redisctl",
          reason: {:repository_identity_unavailable, "redis/redisctl", @gh_error}
        }
      ]
    }

    log = capture_log(fn -> BootProjection.run("x", fn -> {:error, report} end) end)

    refute log =~ "authorization_request"
    refute log =~ "x-github-sso"
  end

  test "a clean projection logs nothing" do
    assert capture_log(fn -> assert :ok = BootProjection.run("x", fn -> {:ok, []} end) end) == ""
  end

  test "an unknown reason is clipped, not dumped" do
    assert String.length(BootProjection.short(String.duplicate("a", 5_000))) <= 200
  end

  test "both projections expose a boot entry point that does not raise" do
    assert :ok = Custode.LegacyMissionProjection.project_at_boot()
    assert :ok = Custode.LegacyRoleBindingProjection.project_at_boot()
  end
end
