defmodule WajadiEngineWeb.Dev.LoadWhatsAppController do
  @moduledoc false

  use WajadiEngineWeb, :controller

  import Ecto.Query

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.ChatHistory
  alias WajadiEngine.WhatsApp.Session

  def upsert_session(conn, %{"user_id" => user_id, "session_id" => session_id}) do
    with {:ok, session} <- get_or_create_session(user_id, session_id),
         {:ok, session} <-
           WhatsApp.mark_session_connected(session, %{phone_number: fake_phone(session_id)}) do
      json(conn, %{success: true, data: session_payload(session)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def send_message(conn, params) do
    attrs = message_attrs(params, true, "sent")

    case WhatsApp.create_outgoing_chat_history(attrs) do
      {:ok, chat_history} ->
        json(conn, %{success: true, data: chat_history_payload(chat_history)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def receive_message(conn, params) do
    attrs = message_attrs(params, false, "received")

    case WhatsApp.create_incoming_chat_history(attrs) do
      {:ok, chat_history} ->
        json(conn, %{success: true, data: chat_history_payload(chat_history)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def session_stats(conn, %{"session_id" => session_id}) do
    stats = %{
      total: count_messages(session_id),
      incoming: count_messages(session_id, false),
      outgoing: count_messages(session_id, true)
    }

    json(conn, %{success: true, data: stats})
  end

  defp get_or_create_session(user_id, session_id) do
    case WhatsApp.get_session(session_id) do
      %Session{user_id: ^user_id} = session -> {:ok, session}
      %Session{} -> {:error, :session_id_taken}
      nil -> WhatsApp.create_session(user_id, %{session_id: session_id})
    end
  end

  defp message_attrs(params, from_me?, status) do
    session_id = Map.fetch!(params, "session_id")
    peer = Map.get(params, "peer", "628000000000@s.whatsapp.net")
    own = Map.get(params, "own", "load-test@s.whatsapp.net")

    %{
      session_id: session_id,
      from: if(from_me?, do: own, else: peer),
      to: if(from_me?, do: peer, else: own),
      from_me: from_me?,
      body: Map.get(params, "body", "load-test-message"),
      type: Map.get(params, "type", "text"),
      status: status
    }
  end

  defp count_messages(session_id) do
    ChatHistory
    |> where([chat_history], chat_history.session_id == ^session_id)
    |> Repo.aggregate(:count)
  end

  defp count_messages(session_id, from_me?) do
    ChatHistory
    |> where(
      [chat_history],
      chat_history.session_id == ^session_id and chat_history.from_me == ^from_me?
    )
    |> Repo.aggregate(:count)
  end

  defp session_payload(session) do
    %{
      user_id: session.user_id,
      session_id: session.session_id,
      status: session.status,
      is_active: session.is_active,
      phone_number: session.phone_number
    }
  end

  defp chat_history_payload(chat_history) do
    %{
      id: chat_history.id,
      session_id: chat_history.session_id,
      from_me: chat_history.from_me,
      status: chat_history.status
    }
  end

  defp fake_phone(session_id) do
    suffix =
      :erlang.phash2(session_id, 1_000_000_000)
      |> Integer.to_string()
      |> String.pad_leading(10, "0")

    "628#{suffix}"
  end

  defp render_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(400)
    |> json(%{
      success: false,
      error: %{reason: "changeset_invalid", details: changeset_errors(changeset)}
    })
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(400)
    |> json(%{success: false, error: %{reason: to_string(reason)}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
