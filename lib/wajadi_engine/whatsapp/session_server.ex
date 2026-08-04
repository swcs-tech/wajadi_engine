defmodule WajadiEngine.WhatsApp.SessionServer do
  @moduledoc """
  Runtime owner for one WhatsApp session connection.
  """

  use GenServer

  require Logger

  alias Amarula.Address
  alias WajadiEngine.AI.Agent
  alias WajadiEngine.ProductCatalog
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.Helpers
  alias WajadiEngine.WhatsApp.TerminalQR

  @registry WajadiEngine.WhatsApp.SessionRegistry
  # Diagnostic target matching the sender PN used by the previous successful test.
  @ping_target "6282111096953@s.whatsapp.net"
  @product_image_receive_timeout 15_000
  @product_image_connect_timeout 5_000
  @max_product_image_bytes 10 * 1024 * 1024

  defstruct [
    :user_id,
    :session_id,
    :conn_pid,
    :conn_monitor,
    :ai_agent,
    connect_on_init?: true,
    ai_async?: true,
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

  @spec send_media(server(), String.t(), Amarula.media_type(), binary(), keyword()) ::
          Amarula.send_result()
  def send_media(server, jid, type, data, opts \\ [])
      when is_binary(jid) and is_binary(data) do
    GenServer.call(server, {:send_media, jid, type, data, opts}, 30_000)
  end

  @impl true
  def init(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      user_id: user_id,
      session_id: session_id,
      connect_on_init?: Keyword.get(opts, :connect, true),
      ai_agent: Keyword.get(opts, :ai_agent, Agent),
      ai_async?: Keyword.get(opts, :ai_async?, true),
      amarula_config: Keyword.get(opts, :amarula_config, %{})
    }

    Logger.info("WhatsApp session runtime started",
      session_id: state.session_id,
      connect_on_init: state.connect_on_init?
    )

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
    with {:ok, state} <- disconnect_amarula(state),
         {:ok, session} <- fetch_and_update_session(state, &WhatsApp.mark_session_disconnected/1) do
      Logger.info("WhatsApp session disconnected", session_id: state.session_id)
      {:reply, {:ok, session}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, state) do
    reply_session_update(state, &WhatsApp.pause_session/1, "WhatsApp session paused")
  end

  def handle_call(:resume, _from, state) do
    if connected_connection?(state) do
      reply_session_update(state, &WhatsApp.resume_session/1, "WhatsApp session resumed")
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:logout, _from, state) do
    state = logout_amarula(state)
    auth_rows_cleared = WhatsApp.clear_auth_states(state.session_id)

    case fetch_and_update_session(state, &WhatsApp.mark_session_disconnected/1) do
      {:ok, session} ->
        Logger.info("WhatsApp session logged out",
          session_id: state.session_id,
          auth_rows_cleared: auth_rows_cleared
        )

        {:reply, {:ok, session}, clear_connection_state(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_connection_state(state)}
    end
  end

  def handle_call(:delete, _from, state) do
    state = logout_amarula(state)

    reply =
      with {:ok, account} <- WhatsApp.fetch_account(state.user_id),
           {:ok, _archived} <- WhatsApp.archive_session(account, state.session_id) do
        :ok
      end

    if match?({:error, _reason}, reply) do
      update_session_best_effort(state, &WhatsApp.mark_session_disconnected/1)
    end

    {:stop, :normal, reply, clear_connection_state(state)}
  end

  def handle_call({:send_reply, jid, text, opts}, _from, state) do
    {save_history?, send_opts} = Keyword.pop(opts, :save_history, true)
    result = send_text_result(state, jid, text, send_opts)

    if save_history? do
      log_outgoing_message(state, jid, text, "text", result)
    end

    {:reply, result, state}
  end

  def handle_call({:send_media, jid, type, data, opts}, _from, state) do
    {save_history?, send_opts} = Keyword.pop(opts, :save_history, true)
    result = send_media_result(state, jid, type, data, send_opts)

    if save_history? do
      log_outgoing_message(
        state,
        jid,
        media_log_body(type, send_opts),
        Atom.to_string(type),
        result
      )
    end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:amarula, :connection_update, %{qr: qr}}, state) when is_binary(qr) do
    update_session_best_effort(state, fn session -> WhatsApp.mark_session_qr(session, qr) end)
    TerminalQR.maybe_print(state.session_id, qr)
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
    update_session_best_effort(state, &mark_runtime_disconnected/1)
    Logger.info("WhatsApp session connection interrupted", session_id: state.session_id)
    {:noreply, state}
  end

  def handle_info({:amarula, :messages_upsert, %{messages: messages}}, state)
      when is_list(messages) do
    Enum.each(messages, &handle_incoming_message(state, &1))

    {:noreply, state}
  end

  def handle_info({:amarula, :error, reason}, state) do
    Logger.warning("WhatsApp connection error",
      session_id: state.session_id,
      reason: safe_reason(reason)
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
      reason: safe_reason(reason)
    )

    {:noreply, %{state | conn_pid: nil, conn_monitor: nil}}
  end

  def handle_info(message, state) do
    Logger.debug("Ignored SessionServer message",
      session_id: state.session_id,
      message: message_kind(message)
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
         {:ok, _session} <- mark_session_starting(session),
         {:ok, pid} <- start_or_adopt_amarula(state) do
      Logger.info("WhatsApp session connection started", session_id: state.session_id)
      {:ok, pid, monitor_connection(%{state | conn_pid: pid})}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_or_adopt_amarula(state) do
    config =
      %{
        profile: state.session_id,
        storage: {WajadiEngine.WhatsApp.Storage.Postgres, []}
      }
      |> Map.merge(Map.new(state.amarula_config))

    config
    |> Amarula.new()
    |> Amarula.connect(parent: self())
    |> case do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_running, pid}} ->
        :ok = Amarula.set_parent(Amarula.via(state.session_id), self())

        case Amarula.reconnect(Amarula.via(state.session_id)) do
          :ok -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_session_starting(%{is_active: true} = session),
    do: WhatsApp.mark_session_reconnecting(session)

  defp mark_session_starting(session), do: WhatsApp.mark_session_connecting(session)

  defp mark_runtime_disconnected(session) do
    if session.is_active do
      WhatsApp.mark_session_reconnecting(session)
    else
      WhatsApp.mark_session_disconnected(session)
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
    case connection_pid(state) do
      nil ->
        {:ok, state}

      pid when is_pid(pid) ->
        case Amarula.disconnect(pid) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
    end
  catch
    :exit, {:noproc, _} -> {:ok, clear_connection_state(state)}
    :exit, {:normal, _} -> {:ok, clear_connection_state(state)}
    :exit, reason -> {:error, reason}
  end

  defp logout_amarula(state) do
    if connected_connection?(state) do
      case Amarula.wipe_credentials(Amarula.via(state.session_id)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("WhatsApp credential wipe failed",
            session_id: state.session_id,
            reason: safe_reason(reason)
          )
      end
    end

    stop_amarula(state.session_id)
    state
  end

  defp clear_connection_state(%{conn_monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | conn_pid: nil, conn_monitor: nil}
  end

  defp clear_connection_state(state), do: %{state | conn_pid: nil, conn_monitor: nil}

  defp stop_amarula(session_id) do
    case Amarula.stop(session_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp stop failed",
          session_id: session_id,
          reason: safe_reason(reason)
        )
    end
  end

  defp connected_connection?(state) do
    case connection_pid(state) do
      nil -> false
      pid -> Amarula.connection_state(pid) == :connected
    end
  catch
    :exit, _reason -> false
  end

  defp connection_pid(state) do
    case Amarula.whereis(state.session_id) do
      pid when is_pid(pid) -> pid
      nil -> state.conn_pid
    end
  end

  defp send_text_result(state, jid, text, opts) do
    if connected_connection?(state) do
      Helpers.send_text(Amarula.via(state.session_id), jid, text, opts)
    else
      {:error, :not_connected}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
  end

  defp send_media_result(state, jid, type, data, opts) do
    if connected_connection?(state) do
      case type do
        :image -> Helpers.send_image(connection_pid(state), jid, data, opts)
        _type -> Helpers.send_media(Amarula.via(state.session_id), jid, type, data, opts)
      end
    else
      {:error, :not_connected}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
  end

  defp handle_incoming_message(state, %Amarula.Msg{} = message) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(state.user_id, state.session_id) do
      case log_incoming_message(state, session, message) do
        {:ok, body} -> maybe_start_ai_reply(state, session, message, body)
        :skip -> :ok
      end
    end
  end

  defp handle_incoming_message(_state, _message), do: :ok

  defp log_incoming_message(_state, _session, %Amarula.Msg{from_me: true}), do: :skip

  defp log_incoming_message(state, session, %Amarula.Msg{} = message) do
    case Helpers.extract_message_content(message) do
      nil ->
        :skip

      body ->
        attrs = %{
          session_id: state.session_id,
          from: inbound_from(message),
          to: inbound_to(state, message),
          body: body,
          type: Helpers.message_type(message)
        }

        case WhatsApp.create_incoming_chat_history(session, attrs) do
          {:ok, _chat_history} ->
            {:ok, body}

          {:error, reason} ->
            Logger.warning("WhatsApp incoming message log failed",
              session_id: state.session_id,
              message_id: bounded_id(message.id),
              reason: safe_reason(reason)
            )

            {:ok, body}
        end
    end
  end

  defp maybe_start_ai_reply(state, session, message, body) do
    with true <- session.status != "paused",
         true <- session.status == "connected",
         true <- connected_connection?(state),
         {:ok, target_jid} <- reply_target(message) do
      context = tenant_context(session)

      cond do
        ping_message?(body) ->
          start_ping_reply(state, context)

        product_image_reply_available?(context, body) ->
          start_product_image_reply(state, context, target_jid, body)

        true ->
          start_ai_reply(state, context, target_jid, body)
      end
    else
      _skip -> :ok
    end
  end

  defp start_ping_reply(%{ai_async?: true} = state, context) do
    case Task.Supervisor.start_child(WajadiEngine.TaskSupervisor, fn ->
           run_direct_reply(state, context, @ping_target, "pong")
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp ping reply task start failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )
    end
  end

  defp start_ping_reply(state, context),
    do: run_direct_reply(state, context, @ping_target, "pong")

  defp run_direct_reply(state, context, target_jid, reply) do
    result = send_text_result(state, target_jid, reply, [])
    log_outgoing_message(state, context, target_jid, reply, "text", result)
  end

  defp ping_message?(body) when is_binary(body) do
    body |> String.trim() |> String.downcase() == "ping"
  end

  defp start_ai_reply(%{ai_async?: true} = state, context, target_jid, body) do
    case Task.Supervisor.start_child(WajadiEngine.TaskSupervisor, fn ->
           run_ai_reply(state, context, target_jid, body)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp AI reply task start failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )
    end
  end

  defp start_ai_reply(state, context, target_jid, body),
    do: run_ai_reply(state, context, target_jid, body)

  defp start_product_image_reply(%{ai_async?: true} = state, context, target_jid, body) do
    case Task.Supervisor.start_child(WajadiEngine.TaskSupervisor, fn ->
           run_product_image_reply(state, context, target_jid, body)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp product image reply task start failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )
    end
  end

  defp start_product_image_reply(state, context, target_jid, body) do
    run_product_image_reply(state, context, target_jid, body)
  end

  defp run_product_image_reply(state, context, target_jid, body) do
    send_chatstate_best_effort(state, target_jid, :composing)

    case product_image_reply(context, body) do
      {:ok, product, image_url} ->
        send_product_image_reply(state, context, target_jid, product, image_url)

      :fallback ->
        run_ai_reply(state, context, target_jid, body)
    end
  after
    send_chatstate_best_effort(state, target_jid, :paused)
  end

  defp product_image_reply_available?(context, body),
    do: product_image_reply(context, body) != :fallback

  defp product_image_reply(context, body) do
    with true <- ProductCatalog.image_request?(body),
         [product] <-
           ProductCatalog.search_products(context.account_id, context.store_id, body),
         image_url when is_binary(image_url) <- ProductCatalog.product_image_url(product) do
      {:ok, product, image_url}
    else
      _fallback -> :fallback
    end
  end

  defp send_product_image_reply(state, context, target_jid, product, image_url) do
    caption = ProductCatalog.product_caption(product)

    case fetch_product_image(image_url) do
      {:ok, bytes} ->
        result = send_media_result(state, target_jid, :image, bytes, caption: caption)
        log_outgoing_message(state, context, target_jid, caption, "image", result)

      {:error, reason} ->
        Logger.warning("Product image fetch failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )

        message = "Maaf, foto #{caption} belum bisa dikirim saat ini."
        result = send_text_result(state, target_jid, message, [])
        log_outgoing_message(state, context, target_jid, message, "text", result)
    end
  end

  defp fetch_product_image("data:" <> _rest = data_url), do: decode_data_url(data_url)

  defp fetch_product_image(url) when is_binary(url) do
    with {:ok, %URI{scheme: "https", host: host}} when is_binary(host) <- URI.new(url),
         true <- allowed_product_image_host?(host) do
      request_product_image(url)
    else
      _invalid_or_disallowed -> {:error, :product_image_host_not_allowed}
    end
  end

  defp fetch_product_image(_url), do: {:error, :missing_product_image_url}

  defp request_product_image(url) do
    case Req.get(url,
           retry: false,
           redirect: false,
           receive_timeout: @product_image_receive_timeout,
           connect_options: [timeout: @product_image_connect_timeout],
           into: &collect_product_image_chunk/2
         ) do
      {:ok, %{status: status, private: private}} when status in 200..299 ->
        if Map.get(private, :wajadi_engine_product_image_too_large?, false) do
          {:error, :product_image_too_large}
        else
          private
          |> Map.get(:wajadi_engine_product_image_chunks, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> then(&{:ok, &1})
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_product_image_host?(host) do
    host = String.downcase(host)

    :wajadi_engine
    |> Application.get_env(:product_image_allowed_hosts, [])
    |> Enum.any?(&(String.downcase(&1) == host))
  end

  defp decode_data_url(data_url) do
    case Regex.run(~r/^data:[^;]+;base64,(?<data>.+)$/s, data_url, capture: ["data"]) do
      [data] when byte_size(data) <= div(@max_product_image_bytes * 4, 3) + 4 ->
        case Base.decode64(data) do
          {:ok, bytes} when byte_size(bytes) <= @max_product_image_bytes -> {:ok, bytes}
          {:ok, _bytes} -> {:error, :product_image_too_large}
          :error -> :error
        end

      [_data] ->
        {:error, :product_image_too_large}

      nil ->
        {:error, :invalid_data_url}
    end
  end

  defp collect_product_image_chunk({:data, data}, {request, response}) when is_binary(data) do
    size = Map.get(response.private, :wajadi_engine_product_image_size, 0) + byte_size(data)

    private =
      response.private
      |> Map.put(:wajadi_engine_product_image_size, size)
      |> Map.update(:wajadi_engine_product_image_chunks, [data], &[data | &1])

    response = %{response | private: private}

    if size > @max_product_image_bytes do
      {:halt, {request, put_in(response.private[:wajadi_engine_product_image_too_large?], true)}}
    else
      {:cont, {request, response}}
    end
  end

  defp run_ai_reply(state, context, target_jid, body) do
    send_chatstate_best_effort(state, target_jid, :composing)

    case state.ai_agent.handle_incoming_message(context, body) do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        result = send_text_result(state, target_jid, reply, [])
        log_outgoing_message(state, context, target_jid, reply, "text", result)

      {:ok, _empty_reply} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp AI reply failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )
    end
  rescue
    exception ->
      Logger.warning("WhatsApp AI reply crashed",
        session_id: state.session_id,
        reason: exception.__struct__
      )
  after
    send_chatstate_best_effort(state, target_jid, :paused)
  end

  defp reply_target(%Amarula.Msg{} = message) do
    case Helpers.address_to_jid(message.channel) do
      jid when is_binary(jid) -> {:ok, jid}
      nil -> {:error, :missing_reply_target}
    end
  end

  defp send_chatstate_best_effort(state, jid, type) do
    if connected_connection?(state) do
      Amarula.send_chatstate(Amarula.via(state.session_id), jid, type)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_outgoing_message(state, jid, body, type, result) do
    log_outgoing_message(state, nil, jid, body, type, result)
  end

  defp log_outgoing_message(state, context, jid, body, type, result) do
    attrs = %{
      session_id: state.session_id,
      from: own_jid(state) || "unknown",
      to: Helpers.format_to_jid(jid),
      body: body,
      type: type,
      status: outgoing_status(result),
      error: outgoing_error(result)
    }

    history_result =
      case context do
        %{store_id: _store_id, session_id: _session_id} ->
          WhatsApp.create_outgoing_chat_history(context, attrs)

        nil ->
          WhatsApp.create_outgoing_chat_history(attrs)
      end

    case history_result do
      {:ok, _chat_history} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp outgoing message log failed",
          session_id: state.session_id,
          status: attrs.status,
          reason: safe_reason(reason)
        )
    end
  end

  defp inbound_from(%Amarula.Msg{} = message) do
    Helpers.address_to_jid(message.from) || Helpers.address_to_jid(message.channel) || "unknown"
  end

  defp inbound_to(state, %Amarula.Msg{} = message) do
    Helpers.address_to_jid(message.to) || own_jid(state) || "unknown"
  end

  defp own_jid(state) do
    case connection_pid(state) do
      pid when is_pid(pid) -> pid |> Amarula.own_address() |> Helpers.address_to_jid()
      _nil -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp outgoing_status({:ok, _result}), do: "sent"
  defp outgoing_status({:error, _reason}), do: "failed"

  defp outgoing_error({:ok, _result}), do: nil
  defp outgoing_error({:error, {:send_rejected, code}}), do: "send_rejected:#{code}"
  defp outgoing_error({:error, reason}), do: inspect(safe_reason(reason))

  defp media_log_body(type, opts), do: Keyword.get(opts, :caption) || "[#{type}]"

  defp reply_session_update(state, fun, success_message) do
    case fetch_and_update_session(state, fun) do
      {:ok, session} ->
        if success_message do
          Logger.info(success_message, session_id: state.session_id, status: session.status)
        end

        {:reply, {:ok, session}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_and_update_session(state, fun) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(state.user_id, state.session_id) do
      fun.(session)
    end
  end

  defp tenant_context(session) do
    %{account_id: session.account_id, store_id: session.store_id, session_id: session.session_id}
  end

  defp update_session_best_effort(state, fun) do
    case fetch_and_update_session(state, fun) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning("WhatsApp session update failed",
          session_id: state.session_id,
          reason: safe_reason(reason)
        )
    end
  end

  defp put_last_connection_error(state, reason) do
    Logger.warning("WhatsApp connection start failed",
      session_id: state.session_id,
      reason: safe_reason(reason)
    )

    state
  end

  defp bounded_id(id) when is_binary(id), do: String.slice(id, 0, 128)
  defp bounded_id(_id), do: nil

  defp message_kind(message) when is_atom(message), do: message

  defp message_kind(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> tag
      _other -> :tuple
    end
  end

  defp message_kind(message) when is_map(message), do: :map
  defp message_kind(message) when is_binary(message), do: :binary
  defp message_kind(_message), do: :unknown

  defp safe_reason(%Ecto.Changeset{}), do: :changeset_invalid
  defp safe_reason(%module{}) when is_atom(module), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_binary(reason), do: :binary_reason

  defp safe_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _other -> :tuple_reason
    end
  end

  defp safe_reason(reason) when is_list(reason), do: :list_reason
  defp safe_reason(_reason), do: :unknown_reason

  defp phone_number_from(%{phone_number: phone_number}) when is_binary(phone_number),
    do: phone_number

  defp phone_number_from(%{"phone_number" => phone_number}) when is_binary(phone_number),
    do: phone_number

  defp phone_number_from(%{me: me}), do: phone_number_from_identity(me)
  defp phone_number_from(%{"me" => me}), do: phone_number_from_identity(me)
  defp phone_number_from(%{identity: identity}), do: phone_number_from_identity(identity)
  defp phone_number_from(%{"identity" => identity}), do: phone_number_from_identity(identity)

  defp phone_number_from(_data), do: nil

  defp phone_number_from_identity(%{id: jid}) when is_binary(jid), do: phone_number_from_jid(jid)

  defp phone_number_from_identity(%{"id" => jid}) when is_binary(jid),
    do: phone_number_from_jid(jid)

  defp phone_number_from_identity(%{jid: jid}) when is_binary(jid), do: phone_number_from_jid(jid)

  defp phone_number_from_identity(%{"jid" => jid}) when is_binary(jid),
    do: phone_number_from_jid(jid)

  defp phone_number_from_identity(jid) when is_binary(jid), do: phone_number_from_jid(jid)

  defp phone_number_from_identity(%Address{} = address) do
    case Address.to_jid(address) do
      {:ok, jid} -> phone_number_from_jid(jid)
      {:error, :no_jid} -> nil
    end
  end

  defp phone_number_from_identity(_identity), do: nil

  defp phone_number_from_jid(jid) do
    jid
    |> String.split("@", parts: 2)
    |> hd()
    |> String.split(":", parts: 2)
    |> hd()
  end
end
