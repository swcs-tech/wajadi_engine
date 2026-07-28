defmodule WajadiEngine.Repo do
  use Ecto.Repo,
    otp_app: :wajadi_engine,
    adapter: Ecto.Adapters.Postgres
end
