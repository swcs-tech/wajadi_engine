defmodule WajadiEngine.WhatsApp.SessionCleanupScheduler do
  @moduledoc """
  Periodic runner for archived WhatsApp session cleanup.
  """

  use GenServer

  require Logger

  alias WajadiEngine.WhatsApp.SessionCleanup

  @default_interval_ms :timer.hours(24)
  @default_batch_size 100

  @type option ::
          {:enabled?, boolean()}
          | {:interval_ms, pos_integer()}
          | {:batch_size, pos_integer()}
          | {:run_on_start?, boolean()}
          | {:cleanup_fun, (keyword() -> SessionCleanup.summary())}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(configured_opts(), opts)

    if Keyword.get(opts, :enabled?, false) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: positive_integer(opts, :interval_ms, @default_interval_ms),
      batch_size: positive_integer(opts, :batch_size, @default_batch_size),
      cleanup_fun: Keyword.get(opts, :cleanup_fun, &SessionCleanup.purge_once/1)
    }

    if Keyword.get(opts, :run_on_start?, false) do
      send(self(), :run_cleanup)
    else
      schedule_next_cleanup(state.interval_ms)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:run_cleanup, state) do
    summary = state.cleanup_fun.(batch_size: state.batch_size)

    Logger.info("Archived WhatsApp session cleanup completed",
      selected: summary.selected,
      purged: summary.purged,
      skipped: summary.skipped,
      failed: summary.failed
    )

    schedule_next_cleanup(state.interval_ms)
    {:noreply, state}
  rescue
    exception ->
      Logger.error("Archived WhatsApp session cleanup crashed", reason: safe_reason(exception))
      schedule_next_cleanup(state.interval_ms)
      {:noreply, state}
  catch
    :exit, reason ->
      Logger.error("Archived WhatsApp session cleanup exited", reason: safe_reason(reason))
      schedule_next_cleanup(state.interval_ms)
      {:noreply, state}
  end

  defp configured_opts do
    Application.get_env(:wajadi_engine, __MODULE__, [])
  end

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp schedule_next_cleanup(interval_ms) do
    Process.send_after(self(), :run_cleanup, interval_ms)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(%module{}) when is_atom(module), do: module
  defp safe_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp safe_reason(_reason), do: :unknown_reason
end
