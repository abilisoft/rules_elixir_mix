defmodule EscriptFixture do
  def main([output]) do
    File.write!(output, "hermetic-escript-ok\n")
  end
end
