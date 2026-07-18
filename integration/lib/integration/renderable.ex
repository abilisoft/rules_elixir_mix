defprotocol Integration.Renderable do
  @moduledoc false

  def render(value)
end

defimpl Integration.Renderable, for: Integer do
  def render(value), do: Integer.to_string(value)
end
