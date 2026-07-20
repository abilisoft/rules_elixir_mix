import Config

config :source_integration_app, SourceIntegrationAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  live_view: [signing_salt: "hermetic-fips-live"],
  pubsub_server: SourceIntegrationApp.PubSub,
  secret_key_base:
    "rules_elixir_mix_fips_phoenix_secret_key_base_000000000000000000000000000000000000",
  server: true,
  url: [host: "localhost"]

config :phoenix, :json_library, Jason
