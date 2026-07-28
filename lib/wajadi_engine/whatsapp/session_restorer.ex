defmodule WajadiEngine.WhatsApp.SessionRestorer do
  @moduledoc """
  Restores active WhatsApp runtime sessions after application boot.
  """

  use GenServer

  require Logger

  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.SessionSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec restore_active_sessions(keyword()) ::
          {:ok, %{started: non_neg_integer(), failed: non_neg_integer()}}
  def restore_active_sessions(opts \\ []) do
    opts = Keyword.put_new(opts, :connect, true)

    result =
      WhatsApp.list_active_sessions_for_restore()
      |> Enum.reduce(%{started: 0, failed: 0}, fn session, acc ->
        case SessionSupervisor.start_session(session.user_id, session.session_id, opts) do
          {:ok, _pid} ->
            %{acc | started: acc.started + 1}

          {:error, reason} ->
            Logger.warning("WhatsApp active session restore failed",
              session_id: session.session_id,
              reason: inspect(reason)
            )

            %{acc | failed: acc.failed + 1}
        end
      end)

    Logger.info("WhatsApp active session restore completed",
      started: result.started,
      failed: result.failed
    )

    {:ok, result}
  end

  @impl true
  def init(opts) do
    if restore_enabled?() do
      {:ok, opts, {:continue, :restore}}
    else
      {:ok, opts}
    end
  end

  @impl true
  def handle_continue(:restore, opts) do
    _result = restore_active_sessions(opts)
    {:noreply, opts}
  rescue
    exception ->
      Logger.error("WhatsApp active session restore crashed",
        reason: Exception.message(exception)
      )

      {:noreply, opts}
  end

  defp restore_enabled? do
    Application.get_env(:wajadi_engine, :whatsapp_restore_active_sessions, true)
  end
end
