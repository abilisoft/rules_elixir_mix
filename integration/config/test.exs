import Config

config :integration, IntegrationWeb.Endpoint,
  secret_key_base:
    "rules_elixir_mix_hermetic_test_secret_key_base_000000000000000000000000000000000000",
  server: false

config :logger, level: :warning
