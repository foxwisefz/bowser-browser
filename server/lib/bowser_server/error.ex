defmodule BowserServer.Error do
  defexception [:status, :code, message: "Request rejected"]
  def fail(status, code), do: raise(__MODULE__, status: status, code: code)
end
