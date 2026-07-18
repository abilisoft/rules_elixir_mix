defmodule RuntimeConsumerTest do
  use ExUnit.Case, async: true

  test "compile-only dependencies do not enter the runtime code path" do
    assert RuntimeConsumer.value() == :compiled
    assert :code.which(CompileOnlyDep) == :non_existing
  end
end
