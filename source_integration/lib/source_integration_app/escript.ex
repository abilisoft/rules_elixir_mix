defmodule SourceIntegrationApp.Escript do
  def main([output]) do
    File.write!(output, "provider-backed-escript-ok\n")
  end
end
