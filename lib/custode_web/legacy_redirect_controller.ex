defmodule CustodeWeb.LegacyRedirectController do
  @moduledoc "Keeps bookmarked legacy dashboard URLs pointed at the console."

  use Phoenix.Controller, formats: [:html]

  alias CustodeWeb.Console.Rail

  def fleet(conn, _params), do: redirect(conn, to: "/")

  def agent(conn, %{"id" => id}), do: redirect(conn, to: Rail.subject_path(id))
end
