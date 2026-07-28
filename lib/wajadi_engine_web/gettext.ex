defmodule WajadiEngineWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.
  """
  use Gettext.Backend, otp_app: :wajadi_engine
end
