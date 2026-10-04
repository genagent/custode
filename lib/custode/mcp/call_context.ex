defmodule Custode.MCP.CallContext do
  @moduledoc "Authenticated caller and origin passed to shared MCP operations."
  @type t :: %__MODULE__{assigns: map()}
  defstruct assigns: %{}
end
