defmodule Custode.RoutinesExampleTest do
  use ExUnit.Case, async: true

  alias Custode.Config.Loader

  # #530: the example is what a second machine starts from, so it has to be a
  # file the loader accepts, and the checked-in config has to be nobody's fleet.
  test "routines.example.toml parses, and its routine normalizes against a real profile" do
    {routines, sensors, _profiles} =
      "routines.example.toml" |> File.read!() |> Loader.parse!("routines.example.toml")

    assert [%{id: "my-repo", repo: "owner/my-repo", profile: profile}] = routines
    assert Map.has_key?(Application.fetch_env!(:custode, :profiles), profile)
    # the sensor is commented out: a copied file polls nothing until edited
    assert sensors == []
  end

  test "config.exs carries no roster and no sensors of its own" do
    config = Config.Reader.read!("config/config.exs", env: :dev)

    assert config[:custode][:routines] == []
    assert config[:custode][:sensors] == []
  end
end
