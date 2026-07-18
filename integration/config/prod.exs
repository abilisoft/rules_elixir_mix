import Config

config :integration, IntegrationWeb.Endpoint,
  force_ssl: [hsts: true],
  server: false
