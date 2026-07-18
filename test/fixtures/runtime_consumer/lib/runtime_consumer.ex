defmodule RuntimeConsumer do
  require CompileOnlyDep

  @compiled CompileOnlyDep.marker()
  def value, do: @compiled
end
