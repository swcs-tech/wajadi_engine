import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :wajadi_engine, WajadiEngine.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "wajadi_engine_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :wajadi_engine, WajadiEngineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2yyDoFPjfsiRljhGDalp3YKIp5icdl2Ohsk5aRm/ubNFrwmhT50PDnHHfc1MB7aC",
  server: false

config :logger, level: :warning

config :wajadi_engine, :whatsapp_restore_active_sessions, false

config :wajadi_engine, :whatsapp_session_start_opts,
  amarula_config: %{
    offline: true,
    connection_state: :connected,
    storage:
      {Amarula.Storage.File, root: Path.join(System.tmp_dir!(), "wajadi_engine_amarula_test")}
  }

config :phoenix, :plug_init_mode, :runtime

config :phoenix,
  sort_verified_routes_query_params: true
