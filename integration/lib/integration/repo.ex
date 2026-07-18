defmodule Integration.Repo do
  use Ecto.Repo,
    otp_app: :integration,
    adapter: Ecto.Adapters.Postgres
end
