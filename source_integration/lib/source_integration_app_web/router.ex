defmodule SourceIntegrationAppWeb.Router do
  use SourceIntegrationAppWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SourceIntegrationAppWeb do
    pipe_through(:browser)
    live("/counter", CounterLive)
  end
end
