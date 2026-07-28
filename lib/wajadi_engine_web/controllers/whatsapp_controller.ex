defmodule WajadiEngineWeb.WhatsAppController do
  use WajadiEngineWeb, :controller

  require Logger

  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.Session
  alias WajadiEngine.WhatsApp.SessionParams
  alias WajadiEngine.WhatsApp.SessionServer
  alias WajadiEngine.WhatsApp.SessionSupervisor

  def list(conn, %{"user_id" => user_id}) do
    sessions = WhatsApp.list_sessions(user_id)

    render_success(
      conn,
      200,
      "List of sessions",
      WajadiEngineWeb.WhatsAppJSON.sessions(%{sessions: sessions})
    )
  end

  def create(conn, %{"user_id" => user_id} = params) do
    with {:ok, attrs} <-
           SessionParams.validate_create(Map.get(params, "_json", Map.drop(params, ["user_id"]))),
         {:ok, session} <- create_or_reuse_session(user_id, attrs),
         {:ok, session} <- WhatsApp.mark_session_connecting(session),
         {:ok, _pid} <- connect_runtime(session) do
      render_success(conn, 201, "Session created", %{
        session_id: session.session_id,
        user_id: session.user_id,
        status: "connecting"
      })
    else
      {:error, errors} when is_list(errors) ->
        render_error(conn, 400, "Validation failed", %{errors: errors})

      {:error, :session_already_connected, session} ->
        render_error(conn, 400, "Session already connected", %{
          session_id: session.session_id,
          status: session.status
        })

      {:error, :session_id_taken} ->
        render_error(conn, 400, "Session ID is not available", %{
          session_id: Map.get(attrs_from_params(params), :session_id)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        render_error(conn, 400, "Validation failed", %{errors: changeset_errors(changeset)})

      {:error, reason} ->
        render_server_error(conn, "whatsapp.create", reason)
    end
  end

  def get_qr(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id) do
      render_success(conn, 200, "Session QR and status", %{
        session_id: session.session_id,
        status: session.status,
        qr: session.qr,
        is_active: session.is_active
      })
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
    end
  end

  def refresh_qr(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         :ok <- stop_runtime(session.session_id),
         {:ok, _session} <- WhatsApp.mark_session_connecting(session),
         {:ok, _pid} <- start_runtime(session) do
      render_success(conn, 200, "QR refreshed", %{session_id: session_id, status: "connecting"})
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
      {:error, reason} -> render_server_error(conn, "whatsapp.refreshQr", reason)
    end
  end

  def connect(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         {:ok, _session} <- WhatsApp.mark_session_connecting(session),
         {:ok, _pid} <- connect_runtime(session) do
      render_success(conn, 200, "Session connecting", %{
        session_id: session_id,
        status: "connecting"
      })
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
      {:error, reason} -> render_server_error(conn, "whatsapp.connect", reason)
    end
  end

  def disconnect(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         {:ok, updated_session} <- disconnect_session(session) do
      render_success(conn, 200, "Session disconnected", %{
        session_id: updated_session.session_id,
        status: updated_session.status
      })
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
      {:error, reason} -> render_server_error(conn, "whatsapp.disconnect", reason)
    end
  end

  def pause(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         {:ok, pid} <- fetch_runtime(session.session_id),
         {:ok, updated_session} <- SessionServer.pause(pid) do
      render_success(conn, 200, "Session paused — bot auto-reply OFF", %{
        session_id: updated_session.session_id,
        status: updated_session.status
      })
    else
      {:error, :not_found} ->
        render_error(conn, 404, "Session not found", nil)

      {:error, :runtime_not_found, session} ->
        render_error(conn, 400, "Session is not active — cannot pause", %{
          session_id: session.session_id,
          status: session.status
        })

      {:error, reason} ->
        render_server_error(conn, "whatsapp.pause", reason)
    end
  end

  def resume(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         {:ok, pid} <- fetch_runtime(session.session_id),
         {:ok, updated_session} <- SessionServer.resume(pid) do
      render_success(conn, 200, "Session resumed — bot auto-reply ON", %{
        session_id: updated_session.session_id,
        status: updated_session.status
      })
    else
      {:error, :not_found} ->
        render_error(conn, 404, "Session not found", nil)

      {:error, :runtime_not_found, session} ->
        render_error(conn, 400, "Session is not active — cannot resume", %{
          session_id: session.session_id,
          status: session.status
        })

      {:error, :not_connected} ->
        render_error(conn, 400, "Session is not active — cannot resume", %{session_id: session_id})

      {:error, reason} ->
        render_server_error(conn, "whatsapp.resume", reason)
    end
  end

  def logout(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         {:ok, updated_session} <- logout_session(session) do
      render_success(conn, 200, "Session logged out", %{
        session_id: updated_session.session_id,
        status: updated_session.status
      })
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
      {:error, reason} -> render_server_error(conn, "whatsapp.logout", reason)
    end
  end

  def delete(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- WhatsApp.fetch_session_for_user(user_id, session_id),
         :ok <- delete_session(session) do
      render_success(conn, 200, "Session deleted permanently", %{session_id: session_id})
    else
      {:error, :not_found} -> render_error(conn, 404, "Session not found", nil)
      {:error, reason} -> render_server_error(conn, "whatsapp.delete", reason)
    end
  end

  defp create_or_reuse_session(user_id, attrs) do
    session_id = Map.get(attrs, :session_id) || WhatsApp.generate_session_id(user_id)

    case WhatsApp.get_session(session_id) do
      %Session{status: "connected"} = session ->
        {:error, :session_already_connected, session}

      %Session{user_id: ^user_id} = session ->
        {:ok, session}

      %Session{} ->
        {:error, :session_id_taken}

      nil ->
        WhatsApp.create_session(user_id, %{session_id: session_id})
    end
  end

  defp start_runtime(%Session{} = session) do
    SessionSupervisor.start_session(session.user_id, session.session_id, session_start_opts())
  end

  defp connect_runtime(%Session{} = session) do
    case SessionSupervisor.whereis(session.session_id) do
      pid when is_pid(pid) -> SessionServer.connect(pid)
      nil -> start_runtime(session)
    end
  end

  defp stop_runtime(session_id) do
    SessionSupervisor.stop_session(session_id)
  end

  defp fetch_runtime(session_id) do
    case SessionSupervisor.whereis(session_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :runtime_not_found, WhatsApp.get_session(session_id)}
    end
  end

  defp disconnect_session(%Session{} = session) do
    case SessionSupervisor.whereis(session.session_id) do
      pid when is_pid(pid) -> SessionServer.disconnect(pid)
      nil -> WhatsApp.mark_session_disconnected(session)
    end
  end

  defp logout_session(%Session{} = session) do
    case SessionSupervisor.whereis(session.session_id) do
      pid when is_pid(pid) -> SessionServer.logout(pid)
      nil -> force_logout_session(session)
    end
  end

  defp force_logout_session(%Session{} = session) do
    WhatsApp.clear_auth_states(session.session_id)
    WhatsApp.mark_session_disconnected(session)
  end

  defp delete_session(%Session{} = session) do
    case SessionSupervisor.whereis(session.session_id) do
      pid when is_pid(pid) -> SessionServer.delete(pid)
      nil -> force_delete_session(session)
    end
  end

  defp force_delete_session(%Session{} = session) do
    WhatsApp.clear_auth_states(session.session_id)

    case WhatsApp.delete_session(session) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_start_opts do
    Application.get_env(:wajadi_engine, :whatsapp_session_start_opts, [])
  end

  defp attrs_from_params(params) do
    case SessionParams.validate_create(Map.drop(params, ["user_id"])) do
      {:ok, attrs} -> attrs
      {:error, _errors} -> %{}
    end
  end

  defp render_success(conn, status, message, data) do
    conn
    |> put_status(status)
    |> render(:success, message: message, data: data)
  end

  defp render_error(conn, status, message, error) do
    conn
    |> put_status(status)
    |> render(:error, message: message, error: error)
  end

  defp render_server_error(conn, source, reason) do
    Logger.error("WhatsApp controller error", source: source, reason: safe_reason(reason))

    conn
    |> put_status(500)
    |> render(:error, message: "Internal Server Error", error: nil)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp safe_reason(%Ecto.Changeset{}), do: :changeset_invalid
  defp safe_reason(%module{}) when is_atom(module), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _other -> :tuple_reason
    end
  end

  defp safe_reason(reason) when is_binary(reason), do: :binary_reason
  defp safe_reason(_reason), do: :unknown_reason
end
