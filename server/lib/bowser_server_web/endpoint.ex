defmodule BowserServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :bowser_server
  plug(BowserServerWeb.Router)
end

defmodule BowserServerWeb.ErrorJSON do
  def render(_, _), do: %{error: %{code: "internal_error"}}
end
