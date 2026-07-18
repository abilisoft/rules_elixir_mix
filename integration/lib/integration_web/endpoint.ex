defmodule IntegrationWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :integration

  @session_options [
    store: :cookie,
    key: "_integration_key",
    signing_salt: "hermetic-live"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :integration,
    gzip: false,
    only: IntegrationWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(IntegrationWeb.Router)
end
