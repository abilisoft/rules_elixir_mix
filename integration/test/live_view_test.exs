defmodule IntegrationWeb.CounterLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint IntegrationWeb.Endpoint

  test "routes, mounts, and handles a stateful event" do
    {:ok, view, html} = live(build_conn(), "/counter")
    assert html =~ ~s(id="count">0)

    assert view
           |> element("#increment")
           |> render_click() =~ ~s(id="count">1)
  end
end
