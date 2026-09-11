defmodule BowserServerWeb.Router do
  use Phoenix.Router

  scope "/", BowserServerWeb do
    get("/updates/stable.json", APIController, :update_manifest, log: false)
    get("/updates/Bowser.dmg", APIController, :update_image, log: false)
    get("/healthz", APIController, :health, log: false)
    post("/v1/registrations", APIController, :register, log: false)
    post("/v1/events", APIController, :events, log: false)
    match(:*, "/v1/registrations", APIController, :method, log: false)
    match(:*, "/v1/events", APIController, :method, log: false)
    match(:*, "/*path", APIController, :website, log: false)
  end
end
