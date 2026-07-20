defmodule SourceIntegrationApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: SourceIntegrationApp.Supervisor)
  end
end
