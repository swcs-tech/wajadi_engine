defmodule WajadiEngineWeb do
  @moduledoc """
  The entrypoint for defining web layer components in WajadiEngine.

  Provides shared macros for controllers, router, and channels used
  by the WhatsApp Engine HTTP API and webhook endpoints.

  Usage in web modules:
      use WajadiEngineWeb, :controller
      use WajadiEngineWeb, :router

  Keep macros in this module focused purely on imports, aliases, and common
  plugs required across all web endpoints.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: WajadiEngineWeb.Endpoint,
        router: WajadiEngineWeb.Router,
        statics: WajadiEngineWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
