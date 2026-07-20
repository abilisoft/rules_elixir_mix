defmodule SourceIntegrationAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :source_integration_app

  @session_options [
    store: :cookie,
    key: "_source_integration_key",
    signing_salt: "hermetic-fips-live"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]
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
  plug(SourceIntegrationAppWeb.Router)
end
