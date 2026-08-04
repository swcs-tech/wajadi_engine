import Config
import Nvir

dotenv!(
  dev: ".env",
  test: ".env.test"
)

database_url =
  case env!("DATABASE_URL", :string!, nil) do
    nil -> nil
    url -> String.trim(url)
  end

if database_url not in [nil, ""] do
  config :wajadi_engine, WajadiEngine.Repo, url: database_url
end

if System.get_env("PHX_SERVER") do
  config :wajadi_engine, WajadiEngineWeb.Endpoint, server: true
end

config :wajadi_engine, WajadiEngineWeb.Endpoint, http: [port: env!("PORT", :integer!, 4000)]

env_string = fn name, default ->
  case env!(name) do
    nil ->
      default

    value ->
      case String.trim(value) do
        "" -> default
        value -> value
      end
  end
end

product_image_allowed_hosts =
  System.get_env("PRODUCT_IMAGE_ALLOWED_HOSTS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :wajadi_engine, :product_image_allowed_hosts, product_image_allowed_hosts

config :wajadi_engine, :ai,
  nine_router_base_url: env_string.("NINE_ROUTER_BASE_URL", "http://localhost:20128/v1"),
  nine_router_api_key: env_string.("NINE_ROUTER_API_KEY", "dummy-key"),
  nine_router_model: env_string.("NINE_ROUTER_MODEL", "gpt-4o")

config :wajadi_engine, WajadiEngine.WhatsApp.SessionCleanupScheduler,
  enabled?: env!("WAJADI_SESSION_CLEANUP_ENABLED", :boolean!, false),
  interval_ms: env!("WAJADI_SESSION_CLEANUP_INTERVAL_MS", :integer!, :timer.hours(24)),
  batch_size: env!("WAJADI_SESSION_CLEANUP_BATCH_SIZE", :integer!, 100),
  run_on_start?: env!("WAJADI_SESSION_CLEANUP_RUN_ON_START", :boolean!, false)

case System.get_env("PRINT_WA_QR") do
  value when value in ["1", "true", "TRUE", "yes", "YES"] ->
    config :wajadi_engine, :whatsapp_print_qr, true

  value when value in ["0", "false", "FALSE", "no", "NO"] ->
    config :wajadi_engine, :whatsapp_print_qr, false

  _unset_or_empty ->
    :ok
end

if config_env() == :prod do
  maybe_ipv6 = if env!("ECTO_IPV6", :boolean!, false), do: [:inet6], else: []

  config :wajadi_engine, WajadiEngine.Repo,
    # ssl: true,
    url: env!("DATABASE_URL", :string!) |> String.trim(),
    pool_size: env!("POOL_SIZE", :integer!, 10),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :wajadi_engine, :dns_cluster_query, env!("DNS_CLUSTER_QUERY", :string!, nil)

  config :wajadi_engine, WajadiEngineWeb.Endpoint,
    url: [host: env!("PHX_HOST", :string!, "example.com"), port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0}
    ],
    secret_key_base: env!("SECRET_KEY_BASE", :string!)
end
