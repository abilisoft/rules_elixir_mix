defmodule SourceIntegrationAppWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint SourceIntegrationAppWeb.Endpoint

  test "runs Phoenix and LiveView on the source-built FIPS runtime" do
    assert :enabled = :crypto.info_fips()
    assert %{link_type: :static} = :crypto.info()

    response =
      build_conn()
      |> get("/counter")
      |> html_response(200)

    assert response =~ ~s(id="counter")
    assert response =~ ~s(id="count">0)
    assert response =~ ~s(phx-click="increment")
  end
end
