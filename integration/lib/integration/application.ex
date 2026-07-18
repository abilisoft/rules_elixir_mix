defmodule Integration.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Integration.PubSub},
      IntegrationWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Integration.Supervisor)
  end

  @impl true
  def config_change(changed, removed, _extra) do
    IntegrationWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
