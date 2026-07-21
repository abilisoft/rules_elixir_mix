defmodule SourceIntegrationAppWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SourceIntegrationAppWeb.Endpoint

  test "runs Phoenix and stateful LiveView on the source-built FIPS runtime" do
    assert :enabled = :crypto.info_fips()
    assert %{link_type: :static} = :crypto.info()

    {:ok, view, response} = live(build_conn(), "/counter")

    assert response =~ ~s(id="counter")
    assert response =~ ~s(id="count">0)
    assert response =~ ~s(phx-click="increment")

    assert view
           |> element("#increment")
           |> render_click() =~ ~s(id="count">1)
  end
end
