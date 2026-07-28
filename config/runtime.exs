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
