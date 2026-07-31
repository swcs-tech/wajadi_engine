defmodule WajadiEngine.WhatsApp do
  @moduledoc """
  Data boundary for WhatsApp session, auth state, and chat history persistence.
  """

  import Ecto.Query

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.ChatHistory
  alias WajadiEngine.WhatsApp.Session

  @type session_result :: {:ok, Session.t()} | {:error, Ecto.Changeset.t() | :not_found}
  @type auth_state_metadata :: %{
          type: String.t(),
          key: String.t(),
          encoding: AuthState.encoding(),
          updated_at: DateTime.t()
        }

  @spec generate_session_id(String.t()) :: String.t()
  def generate_session_id(user_id) when is_binary(user_id) do
    "#{user_id}_#{System.system_time(:millisecond)}"
  end

  @spec create_session(String.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(user_id, attrs \\ %{}) when is_binary(user_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs, session_fields())
    session_id = session_id_from(attrs) || generate_session_id(user_id)
    attrs = Map.merge(attrs, %{user_id: user_id, session_id: session_id})

    %Session{}
    |> Session.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec list_sessions(String.t()) :: [Session.t()]
  def list_sessions(user_id) when is_binary(user_id) do
    Session
    |> where([session], session.user_id == ^user_id)
    |> order_by([session], desc: session.inserted_at)
    |> Repo.all()
  end

  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(session_id) when is_binary(session_id) do
    Repo.get_by(Session, session_id: session_id)
  end

  @spec fetch_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def fetch_session(session_id) when is_binary(session_id) do
    case get_session(session_id) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  @spec fetch_session_for_user(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, :not_found}
  def fetch_session_for_user(user_id, session_id)
      when is_binary(user_id) and is_binary(session_id) do
    case Repo.get_by(Session, user_id: user_id, session_id: session_id) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  @spec list_active_sessions_for_restore() :: [Session.t()]
  def list_active_sessions_for_restore do
    Session
    |> join(:inner, [session], auth_state in AuthState,
      on:
        auth_state.session_id == session.session_id and auth_state.type == "creds" and
          auth_state.key == "creds"
    )
    |> where([session, _auth_state], session.status != "paused")
    |> order_by([session], asc: session.inserted_at)
    |> Repo.all()
  end

  @spec delete_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def delete_session(%Session{} = session), do: Repo.delete(session)

  @spec mark_session_connecting(Session.t()) :: session_result()
  def mark_session_connecting(%Session{} = session) do
    update_session(session, %{status: "connecting", is_active: false, qr: nil})
  end

  @spec mark_session_reconnecting(Session.t()) :: session_result()
  def mark_session_reconnecting(%Session{} = session) do
    update_session(session, %{status: "connecting", is_active: true, qr: nil})
  end

  @spec mark_session_qr(Session.t(), String.t()) :: session_result()
  def mark_session_qr(%Session{} = session, qr) when is_binary(qr) do
    update_session(session, %{status: "qr", is_active: false, qr: qr, last_qr_at: now()})
  end

  @spec mark_session_connected(Session.t(), map()) :: session_result()
  def mark_session_connected(%Session{} = session, attrs \\ %{}) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_attrs([:phone_number])
      |> Map.merge(%{status: "connected", is_active: true, qr: nil, last_connected_at: now()})

    update_session(session, attrs)
  end

  @spec mark_session_disconnected(Session.t()) :: session_result()
  def mark_session_disconnected(%Session{} = session) do
    update_session(session, %{
      status: "disconnected",
      is_active: false,
      qr: nil,
      last_disconnected_at: now()
    })
  end

  @spec pause_session(Session.t()) :: session_result()
  def pause_session(%Session{} = session) do
    update_session(session, %{status: "paused", is_active: true})
  end

  @spec resume_session(Session.t()) :: session_result()
  def resume_session(%Session{} = session) do
    update_session(session, %{status: "connected", is_active: true})
  end

  @spec create_incoming_chat_history(map()) ::
          {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_incoming_chat_history(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs(chat_history_fields())
    |> Map.merge(%{from_me: false, status: "received"})
    |> create_chat_history()
  end

  @spec create_outgoing_chat_history(map()) ::
          {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_outgoing_chat_history(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs(chat_history_fields())
    |> Map.put(:from_me, true)
    |> Map.put_new(:status, "sent")
    |> create_chat_history()
  end

  @spec create_chat_history(map()) :: {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_chat_history(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_attrs(chat_history_fields())
      |> Map.put_new(:type, "text")

    %ChatHistory{}
    |> ChatHistory.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec delete_auth_state(String.t(), String.t(), String.t()) :: :ok
  def delete_auth_state(session_id, type, key)
      when is_binary(session_id) and is_binary(type) and is_binary(key) do
    AuthState
    |> where(
      [auth_state],
      auth_state.session_id == ^session_id and auth_state.type == ^type and auth_state.key == ^key
    )
    |> Repo.delete_all()

    :ok
  end

  @spec clear_auth_states(String.t()) :: non_neg_integer()
  def clear_auth_states(session_id) when is_binary(session_id) do
    {count, nil} =
      AuthState
      |> where([auth_state], auth_state.session_id == ^session_id)
      |> Repo.delete_all()

    count
  end

  @spec list_auth_state_metadata(String.t()) :: [auth_state_metadata()]
  def list_auth_state_metadata(session_id) when is_binary(session_id) do
    AuthState
    |> where([auth_state], auth_state.session_id == ^session_id)
    |> order_by([auth_state], asc: auth_state.type, asc: auth_state.key)
    |> select([auth_state], %{
      type: auth_state.type,
      key: auth_state.key,
      encoding: auth_state.encoding,
      updated_at: auth_state.updated_at
    })
    |> Repo.all()
  end

  @spec count_chat_histories(String.t()) :: non_neg_integer()
  def count_chat_histories(session_id) when is_binary(session_id) do
    ChatHistory
    |> where([chat_history], chat_history.session_id == ^session_id)
    |> Repo.aggregate(:count)
  end

  @spec create_auth_state(map()) :: {:ok, AuthState.t()} | {:error, Ecto.Changeset.t()}
  def create_auth_state(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs, auth_state_fields())

    %AuthState{}
    |> AuthState.create_changeset(attrs)
    |> Repo.insert()
  end

  defp update_session(%Session{} = session, attrs) do
    session
    |> Session.update_changeset(attrs)
    |> Repo.update()
  end

  defp session_id_from(attrs) do
    Map.get(attrs, :session_id)
  end

  defp normalize_attrs(attrs, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      string_key = Atom.to_string(field)

      case {Map.fetch(attrs, field), Map.fetch(attrs, string_key)} do
        {{:ok, value}, _} -> Map.put(acc, field, value)
        {:error, {:ok, value}} -> Map.put(acc, field, value)
        {:error, :error} -> acc
      end
    end)
  end

  defp session_fields do
    [
      :session_id,
      :phone_number,
      :status,
      :qr,
      :is_active,
      :last_connected_at,
      :last_disconnected_at,
      :last_qr_at
    ]
  end

  defp chat_history_fields do
    [:session_id, :from, :to, :from_me, :body, :type, :status, :error]
  end

  defp auth_state_fields do
    [:session_id, :type, :key, :value, :encoding]
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
