defmodule SourceIntegrationAppWeb.CounterLive do
  use SourceIntegrationAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="counter">
      <span id="count">{@count}</span>
      <button id="increment" phx-click="increment">increment</button>
    </main>
    """
  end
end
