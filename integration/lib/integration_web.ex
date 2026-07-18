defmodule IntegrationWeb do
  @moduledoc false

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      alias Phoenix.LiveView.JS
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
