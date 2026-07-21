defmodule IntegrationWeb.CounterLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint IntegrationWeb.Endpoint

  test "routes and renders a LiveView with a fully static OTP runtime" do
    response =
      build_conn()
      |> get("/counter")
      |> html_response(200)

    assert response =~ ~s(id="counter")
    assert response =~ ~s(id="count">0)
    assert response =~ ~s(phx-click="increment")
  end

  test "handles the LiveView event without a dynamic DOM parser" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, count: 0}}

    assert {:noreply, updated} =
             IntegrationWeb.CounterLive.handle_event("increment", %{}, socket)

    assert updated.assigns.count == 1
  end
end
