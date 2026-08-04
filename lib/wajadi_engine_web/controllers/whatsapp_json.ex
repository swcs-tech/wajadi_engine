defmodule WajadiEngineWeb.WhatsAppJSON do
  alias WajadiEngine.WhatsApp.Session

  def success(%{message: message, data: data}) do
    %{success: true, status: "success", message: message, data: data}
  end

  def error(%{message: message, error: error}) do
    %{success: false, status: "error", message: message, error: error}
  end

  def error(%{message: message}) do
    %{success: false, status: "error", message: message, error: nil}
  end

  def session(%Session{} = session), do: render_session(session)

  def sessions(%{sessions: sessions}) do
    %{sessions: Enum.map(sessions, &render_session/1)}
  end

  defp render_session(%Session{} = session) do
    %{
      session_id: session.session_id,
      account_id: session.account_id,
      store_id: session.store_id,
      user_id: session.user_id,
      phone_number: session.phone_number,
      status: session.status,
      qr: session.qr,
      is_active: session.is_active,
      last_connected_at: session.last_connected_at,
      last_disconnected_at: session.last_disconnected_at,
      archived_at: session.archived_at,
      purge_at: session.purge_at,
      created_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end
end
