defmodule CompileOnlyDep do
  defmacro marker do
    quote do: :compiled
  end
end
