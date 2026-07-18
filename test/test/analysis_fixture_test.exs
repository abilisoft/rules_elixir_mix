defmodule AnalysisFixtureTest do
  use ExUnit.Case, async: true

  test "fixture is available" do
    assert AnalysisFixture.value() == :ok
    assert GeneratedAnalysisFixture.value() == :generated
    assert AnalysisProtocol.value(:protocol) == :protocol
  end
end
