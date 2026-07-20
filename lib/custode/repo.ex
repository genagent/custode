defmodule Custode.Repo do
  use Ecto.Repo, otp_app: :custode, adapter: Ecto.Adapters.SQLite3
end
