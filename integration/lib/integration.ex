defmodule Integration do
  @moduledoc false

  def round_trip(message, secret) do
    signed = Plug.Crypto.sign(secret, "integration", message)
    Plug.Crypto.verify(secret, "integration", signed)
  end

  def telemetry_available?, do: is_list(:telemetry.list_handlers([]))
end
