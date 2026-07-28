defmodule WajadiEngine.WhatsApp.SessionServer do
  @moduledoc """
  Runtime owner for one WhatsApp session connection.
  """

  use GenServer

  require Logger

  alias WajadiEngine.WhatsApp

  @registry WajadiEngine.WhatsApp.SessionRegistry

  defstruct [
    :user_id,
    :session_id,
    :conn_pid,
    :conn_monitor,
    connect_on_init?: true,
    amarula_config: %{}
  ]

  @type server :: GenServer.server()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 10_000,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id), do: {:via, Registry, {@registry, session_id}}

  @spec connect(server()) :: {:ok, pid()} | {:error, term()}
  def connect(server), do: GenServer.call(server, :connect, 30_000)

  @spec disconnect(server()) :: {:ok, WhatsApp.Session.t()} | {:error, term()}
  def disconnect(server), do: GenServer.call(server, :disconnect, 30_000)

  @spec pause(server()) :: {:ok, WhatsApp.Session.t()} | {:error, term()}
  def pause(server), do: GenServer.call(server, :pause)

  @spec resume(server()) :: {:ok, WhatsApp.Session.t()} | {:error, term()}
  def resume(server), do: GenServer.call(server, :resume)

  @spec logout(server()) :: {:ok, WhatsApp.Session.t()} | {:error, term()}
  def logout(server), do: GenServer.call(server, :logout, 30_000)

  @spec delete(server()) :: :ok | {:error, term()}
  def delete(server), do: GenServer.call(server, :delete, 30_000)

  @spec send_reply(server(), String.t(), String.t(), keyword()) :: Amarula.send_result()
  def send_reply(server, jid, text, opts \\ []) when is_binary(jid) and is_binary(text) do
    GenServer.call(server, {:send_reply, jid, text, opts}, 30_000)
  end

  @impl true
  def init(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      user_id: user_id,
      session_id: session_id,
      connect_on_init?: Keyword.get(opts, :connect, true),
      amarula_config: Keyword.get(opts, :amarula_config, %{})
    }

    if state.connect_on_init? do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case do_connect(state) do
      {:ok, _pid, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, put_last_connection_error(state, reason)}
    end
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case do_connect(state) do
      {:ok, pid, state} ->
        {:reply, {:ok, pid}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, put_last_connection_error(state, reason)}
    end
  end

  def handle_call(:disconnect, _from, state) do
    state = disconnect_amarula(state)

    case fetch_and_update_session(state, &WhatsApp.mark_session_disconnected/1) do
      {:ok, session} -> {:reply, {:ok, session}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, state) do
    reply_session_update(state, &WhatsApp.pause_session/1)
  end

  def handle_call(:resume, _from, state) do
    if live_connection?(state) do
      reply_session_update(state, &WhatsApp.resume_session/1)
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:logout, _from, state) do
    state = wipe_credentials(state)
    WhatsApp.clear_auth_states(state.session_id)

    case fetch_and_update_session(state, &WhatsApp.mark_session_disconnected/1) do
      {:ok, session} -> {:reply, {:ok, session}, %{state | conn_pid: nil, conn_monitor: nil}}
      {:error, reason} -> {:reply, {:error, reason}, %{state | conn_pid: nil, conn_monitor: nil}}
    end
  end

  def handle_call(:delete, _from, state) do
    state = wipe_credentials(state)
    WhatsApp.clear_auth_states(state.session_id)

    reply =
      with {:ok, session} <- WhatsApp.fetch_session_for_user(state.user_id, state.session_id),
           {:ok, _deleted} <- WhatsApp.delete_session(session) do
        :ok
      end

    {:stop, :normal, reply, %{state | conn_pid: nil, conn_monitor: nil}}
  end

  def handle_call({:send_reply, jid, text, opts}, _from, state) do
    if live_connection?(state) do
      {:reply, Amarula.send_text(Amarula.via(state.session_id), jid, text, opts), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_info({:amarula, :connection_update, %{qr: qr}}, state) when is_binary(qr) do
    update_session_best_effort(state, fn session -> WhatsApp.mark_session_qr(session, qr) end)
    Logger.info("WhatsApp QR received", session_id: state.session_id)
    {:noreply, state}
  end

  def handle_info({:amarula, :connection_update, %{connection: :open} = data}, state) do
    update_session_best_effort(state, fn session ->
      WhatsApp.mark_session_connected(session, %{phone_number: phone_number_from(data)})
    end)

    Logger.info("WhatsApp session connected", session_id: state.session_id)
    {:noreply, state}
  end

  def handle_info({:amarula, :connection_update, %{connection: connection}}, state)
      when connection in [:closed, :disconnected] do
    update_session_best_effort(state, &WhatsApp.mark_session_disconnected/1)
    Logger.info("WhatsApp session disconnected", session_id: state.session_id)
    {:noreply, state}
  end

  def handle_info({:amarula, :messages_upsert, %{messages: messages}}, state)
      when is_list(messages) do
    {:noreply, state}
  end

  def handle_info({:amarula, :error, reason}, state) do
    Logger.warning("WhatsApp connection error",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    {:noreply, state}
  end

  def handle_info({:amarula, event, _data}, state) when is_atom(event) do
    Logger.debug("Ignored Amarula event", session_id: state.session_id, event: event)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{conn_monitor: ref, conn_pid: pid} = state
      ) do
    Logger.warning("WhatsApp connection process down",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    {:noreply, %{state | conn_pid: nil, conn_monitor: nil}}
  end

  def handle_info(message, state) do
    Logger.debug("Ignored SessionServer message",
      session_id: state.session_id,
      message: inspect(elem_tuple(message, 0))
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_amarula(state.session_id)
    :ok
  end

  defp do_connect(state) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(state.user_id, state.session_id),
         {:ok, _session} <- WhatsApp.mark_session_connecting(session),
         {:ok, pid} <- start_or_adopt_amarula(state) do
      {:ok, pid, monitor_connection(%{state | conn_pid: pid})}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_or_adopt_amarula(state) do
    config =
      state.amarula_config
      |> Map.new()
      |> Map.merge(%{
        profile: state.session_id,
        storage: {WajadiEngine.WhatsApp.Storage.Postgres, []}
      })

    config
    |> Amarula.new()
    |> Amarula.connect(parent: self())
    |> case do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_running, pid}} ->
        :ok = Amarula.set_parent(Amarula.via(state.session_id), self())
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp monitor_connection(%{conn_monitor: old_ref} = state) when is_reference(old_ref) do
    Process.demonitor(old_ref, [:flush])
    monitor_connection(%{state | conn_monitor: nil})
  end

  defp monitor_connection(%{conn_pid: pid} = state) when is_pid(pid) do
    %{state | conn_monitor: Process.monitor(pid)}
  end

  defp monitor_connection(state), do: state

  defp disconnect_amarula(state) do
    if live_connection?(state), do: Amarula.disconnect(Amarula.via(state.session_id))
    state
  end

  defp wipe_credentials(state) do
    if live_connection?(state) do
      case Amarula.wipe_credentials(Amarula.via(state.session_id)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("WhatsApp credential wipe failed",
            session_id: state.session_id,
            reason: inspect(reason)
          )
      end
    end

    stop_amarula(state.session_id)
    state
  end

  defp stop_amarula(session_id) do
    case Amarula.stop(session_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp stop failed", session_id: session_id, reason: inspect(reason))
    end
  end

  defp live_connection?(state), do: not is_nil(Amarula.whereis(state.session_id))

  defp reply_session_update(state, fun) do
    case fetch_and_update_session(state, fun) do
      {:ok, session} -> {:reply, {:ok, session}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_and_update_session(state, fun) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(state.user_id, state.session_id) do
      fun.(session)
    end
  end

  defp update_session_best_effort(state, fun) do
    case fetch_and_update_session(state, fun) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp session update failed",
          session_id: state.session_id,
          reason: inspect(reason)
        )
    end
  end

  defp put_last_connection_error(state, reason) do
    Logger.warning("WhatsApp connection start failed",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    state
  end

  defp phone_number_from(%{phone_number: phone_number}) when is_binary(phone_number),
    do: phone_number

  defp phone_number_from(%{"phone_number" => phone_number}) when is_binary(phone_number),
    do: phone_number

  defp phone_number_from(_data), do: nil

  defp elem_tuple(tuple, index) when is_tuple(tuple) and tuple_size(tuple) > index do
    elem(tuple, index)
  end

  defp elem_tuple(message, _index), do: message
end
