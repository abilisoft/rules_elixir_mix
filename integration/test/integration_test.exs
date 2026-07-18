defmodule IntegrationTest do
  use ExUnit.Case, async: true

  test "uses checksum-pinned Mix and Rebar Hex dependencies" do
    assert Integration.round_trip(%{answer: 42}, "secret") == {:ok, %{answer: 42}}
    assert Integration.telemetry_available?()
    assert Integration.GeneratedByBazel.value() == :generated
    assert Integration.Renderable.render(42) == "42"
  end
end
