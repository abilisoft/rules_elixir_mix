defprotocol AnalysisProtocol do
  def value(term)
end

defimpl AnalysisProtocol, for: Atom do
  def value(term), do: term
end
