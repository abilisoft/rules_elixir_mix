defmodule SourceIntegrationApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: SourceIntegrationApp.PubSub},
      SourceIntegrationAppWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SourceIntegrationApp.Supervisor
    )
  end

  @impl true
  def config_change(changed, removed, _extra) do
    SourceIntegrationAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
