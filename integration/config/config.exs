import Config

config :integration, Integration.Repo,
  database: "rules_elixir_mix",
  hostname: "127.0.0.1",
  pool_size: 2

config :integration, IntegrationWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  live_view: [signing_salt: "hermetic-live"],
  pubsub_server: Integration.PubSub,
  secret_key_base:
    "rules_elixir_mix_hermetic_integration_secret_key_base_00000000000000000000000000000000",
  server: false,
  url: [host: "localhost"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
