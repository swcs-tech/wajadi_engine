defmodule WajadiEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {:ok, _} = Application.ensure_all_started(:os_mon)

    children = [
      WajadiEngineWeb.Telemetry,
      WajadiEngine.Repo,
      Amarula.Supervisor,
      {Task.Supervisor, name: WajadiEngine.TaskSupervisor},
      {Registry, keys: :unique, name: WajadiEngine.WhatsApp.SessionRegistry},
      WajadiEngine.WhatsApp.SessionSupervisor,
      WajadiEngine.WhatsApp.SessionRestorer,
      WajadiEngine.WhatsApp.SessionCleanupScheduler,
      {DNSCluster, query: Application.get_env(:wajadi_engine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WajadiEngine.PubSub},
      # Start a worker by calling: WajadiEngine.Worker.start_link(arg)
      # {WajadiEngine.Worker, arg},
      # Start to serve requests, typically the last entry
      WajadiEngineWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WajadiEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WajadiEngineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
