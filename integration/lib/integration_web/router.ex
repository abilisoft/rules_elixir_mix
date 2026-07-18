defmodule IntegrationWeb.Router do
  use IntegrationWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'self'; object-src 'none'; base-uri 'self'"
    })
  end

  scope "/", IntegrationWeb do
    pipe_through(:browser)
    live("/counter", CounterLive)
  end
end
