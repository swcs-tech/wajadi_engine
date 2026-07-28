defmodule WajadiEngine.WhatsApp.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for runtime WhatsApp session processes.
  """

  use DynamicSupervisor

  alias WajadiEngine.WhatsApp.SessionServer

  @registry WajadiEngine.WhatsApp.SessionRegistry

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(String.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(user_id, session_id, opts \\ [])
      when is_binary(user_id) and is_binary(session_id) and is_list(opts) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        child_opts =
          opts |> Keyword.put(:user_id, user_id) |> Keyword.put(:session_id, session_id)

        DynamicSupervisor.start_child(__MODULE__, {SessionServer, child_opts})
    end
  end

  @spec stop_session(String.t()) :: :ok | {:error, :not_found | term()}
  def stop_session(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> terminate_child(pid)
    end
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp terminate_child(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> GenServer.stop(pid, :normal)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:noproc, _} -> :ok
  end
end
