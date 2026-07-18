defmodule AnalysisFixtureSecondTest do
  use ExUnit.Case, async: true

  test "a second test file is available for Bazel sharding" do
    assert AnalysisProtocol.value(:second) == :second
  end
end
