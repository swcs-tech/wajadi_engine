defmodule WajadiEngine.WhatsApp do
  @moduledoc """
  Data boundary for WhatsApp session, auth state, and chat history persistence.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.ChatHistory
  alias WajadiEngine.WhatsApp.Session

  @archive_retention_days 90

  @type session_error ::
          Ecto.Changeset.t()
          | :not_found
          | :store_not_available
          | :purge_deadline_passed
          | :store_occupied

  @type session_result :: {:ok, Session.t()} | {:error, session_error()}
  @type auth_state_metadata :: %{
          type: String.t(),
          key: String.t(),
          encoding: AuthState.encoding(),
          updated_at: DateTime.t()
        }

  @spec generate_session_id(String.t()) :: String.t()
  def generate_session_id(user_id) when is_binary(user_id) do
    "#{user_id}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec create_session(String.t(), map()) :: session_result()
  def create_session(user_id, attrs \\ %{}) when is_binary(user_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs, [:store_id | session_fields()])
    normalized_user_id = normalize_user_id(user_id)
    session_id = session_id_from(attrs) || generate_session_id(normalized_user_id)
    store_id = Map.get(attrs, :store_id)
    attrs = attrs |> Map.delete(:store_id) |> Map.put(:session_id, session_id)

    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      get_or_create_account(repo, normalized_user_id)
    end)
    |> Multi.run(:store, fn repo, %{account: account} ->
      get_or_create_session_store(repo, account, store_id, session_id)
    end)
    |> Multi.insert(:session, fn %{account: account, store: store} ->
      Session.create_changeset(%Session{}, account, store, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  @spec fetch_account(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch_account(user_id) when is_binary(user_id) do
    case Repo.get_by(Account, email: normalize_user_id(user_id)) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  @spec list_sessions(String.t()) :: [Session.t()]
  def list_sessions(user_id) when is_binary(user_id) do
    user_id = normalize_user_id(user_id)

    Session
    |> where([session], session.user_id == ^user_id)
    |> where([session], is_nil(session.archived_at))
    |> order_by([session], desc: session.inserted_at)
    |> Repo.all()
  end

  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(session_id) when is_binary(session_id) do
    Session
    |> where([session], session.session_id == ^session_id)
    |> where([session], is_nil(session.archived_at))
    |> Repo.one()
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
    with {:ok, account} <- fetch_account(user_id) do
      fetch_session_for_account(account, session_id)
    end
  end

  @spec fetch_session_for_account(Account.t(), String.t()) :: session_result()
  def fetch_session_for_account(%Account{id: account_id}, session_id)
      when is_binary(session_id) do
    case active_session_query(account_id, session_id) |> Repo.one() do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  @spec fetch_archived_session(Account.t(), String.t()) :: session_result()
  def fetch_archived_session(%Account{id: account_id}, session_id) when is_binary(session_id) do
    query =
      Session
      |> where([session], session.account_id == ^account_id)
      |> where([session], session.session_id == ^session_id)
      |> where([session], not is_nil(session.archived_at))

    case Repo.one(query) do
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
    |> where([session, _auth_state], is_nil(session.archived_at))
    |> order_by([session], asc: session.inserted_at)
    |> Repo.all()
  end

  @spec delete_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def delete_session(%Session{} = session), do: Repo.delete(session)

  @spec discard_session_creation(Session.t(), boolean()) :: :ok | {:error, term()}
  def discard_session_creation(%Session{} = session, delete_store?) do
    Multi.new()
    |> Multi.delete_all(
      :auth_states,
      from(auth_state in AuthState, where: auth_state.session_id == ^session.session_id)
    )
    |> Multi.delete(:session, session)
    |> Multi.run(:store, fn repo, _changes ->
      store = repo.get!(Store, session.store_id)
      discard_session_store(repo, store, delete_store?)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  @spec move_session(Account.t(), String.t(), integer()) :: session_result()
  def move_session(%Account{} = account, session_id, target_store_id)
      when is_binary(session_id) and is_integer(target_store_id) do
    Multi.new()
    |> Multi.run(:session, fn repo, _changes ->
      lock_active_session(repo, account.id, session_id)
    end)
    |> Multi.run(:target_store, fn repo, %{session: session} ->
      lock_assignment_store(repo, account.id, target_store_id, session.id)
    end)
    |> Multi.run(:source_store, fn repo, %{session: session} ->
      lock_store(repo, account.id, session.store_id, false)
    end)
    |> Multi.run(:moved_session, fn repo, %{session: session, target_store: target_store} ->
      if session.store_id == target_store.id do
        {:ok, session}
      else
        session
        |> Session.assignment_changeset(target_store)
        |> repo.update()
      end
    end)
    |> Multi.run(:source_status, fn repo, changes ->
      update_source_store_after_move(repo, changes)
    end)
    |> Multi.run(:target_status, fn repo, %{target_store: target_store} ->
      update_store_status(repo, target_store, "active")
    end)
    |> Repo.transaction()
    |> multi_result(:moved_session)
  end

  @spec archive_session(Account.t(), String.t(), DateTime.t()) :: session_result()
  def archive_session(%Account{} = account, session_id, archived_at \\ now())
      when is_binary(session_id) do
    purge_at = DateTime.add(archived_at, @archive_retention_days, :day)

    Multi.new()
    |> Multi.run(:session, fn repo, _changes ->
      lock_active_session(repo, account.id, session_id)
    end)
    |> Multi.run(:store, fn repo, %{session: session} ->
      lock_store(repo, account.id, session.store_id, false)
    end)
    |> Multi.run(:auth_states, fn repo, %{session: session} ->
      {count, nil} =
        AuthState
        |> where([auth_state], auth_state.session_id == ^session.session_id)
        |> repo.delete_all()

      {:ok, count}
    end)
    |> Multi.run(:archived_session, fn repo, %{session: session} ->
      session
      |> Session.archive_changeset(archived_at, purge_at)
      |> repo.update()
    end)
    |> Multi.run(:store_status, fn repo, %{store: store} ->
      update_store_status(repo, store, "unassigned")
    end)
    |> Repo.transaction()
    |> multi_result(:archived_session)
  end

  @spec restore_session(Account.t(), String.t(), DateTime.t()) :: session_result()
  def restore_session(%Account{} = account, session_id, current_time \\ now())
      when is_binary(session_id) do
    Multi.new()
    |> Multi.run(:session, fn repo, _changes ->
      lock_restorable_session(repo, account.id, session_id, current_time)
    end)
    |> Multi.run(:store, fn repo, %{session: session} ->
      lock_assignment_store(repo, account.id, session.store_id, session.id)
    end)
    |> Multi.run(:auth_states, fn repo, %{session: session} ->
      {count, nil} =
        AuthState
        |> where([auth_state], auth_state.session_id == ^session.session_id)
        |> repo.delete_all()

      {:ok, count}
    end)
    |> Multi.run(:restored_session, fn repo, %{session: session} ->
      session
      |> Session.restore_changeset(current_time)
      |> repo.update()
    end)
    |> Multi.run(:store_status, fn repo, %{store: store} ->
      update_store_status(repo, store, "active")
    end)
    |> Repo.transaction()
    |> multi_result(:restored_session)
  end

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

  @spec create_incoming_chat_history(Session.t(), map()) ::
          {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_incoming_chat_history(%Session{} = session, attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs(chat_history_fields())
    |> Map.merge(%{session_id: session.session_id, from_me: false, status: "received"})
    |> create_chat_history(session.store_id)
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

  @spec create_outgoing_chat_history(map(), map()) ::
          {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_outgoing_chat_history(
        %{store_id: store_id, session_id: session_id},
        attrs
      )
      when is_integer(store_id) and is_binary(session_id) and is_map(attrs) do
    attrs
    |> normalize_attrs(chat_history_fields())
    |> Map.merge(%{store_id: store_id, session_id: session_id, from_me: true})
    |> Map.put_new(:status, "sent")
    |> create_chat_history(store_id)
  end

  @spec create_chat_history(map()) :: {:ok, ChatHistory.t()} | {:error, Ecto.Changeset.t()}
  def create_chat_history(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_attrs(chat_history_fields())
      |> Map.put_new(:type, "text")
      |> put_chat_history_store_id()

    %ChatHistory{}
    |> ChatHistory.create_changeset(attrs)
    |> Repo.insert()
  end

  defp create_chat_history(attrs, store_id) do
    attrs =
      attrs
      |> normalize_attrs([:store_id | chat_history_fields()])
      |> Map.put(:store_id, store_id)
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

  defp get_or_create_session_store(repo, account, nil, session_id) do
    %Store{}
    |> Store.create_changeset(account, %{name: default_store_name(session_id)}, "active")
    |> repo.insert()
  end

  defp get_or_create_session_store(repo, account, store_id, _session_id)
       when is_integer(store_id) do
    with {:ok, store} <- lock_store(repo, account.id, store_id, false),
         "unassigned" <- store.status,
         false <- store_has_non_archived_session?(repo, store.id),
         {:ok, store} <- update_store_status(repo, store, "active") do
      {:ok, store}
    else
      _unavailable -> {:error, :store_not_available}
    end
  end

  defp get_or_create_session_store(_repo, _account, _store_id, _session_id),
    do: {:error, :store_not_available}

  defp get_or_create_account(repo, email) do
    changeset = Account.create_changeset(%Account{}, %{email: email})

    if changeset.valid? do
      do_get_or_create_account(repo, Ecto.Changeset.get_change(changeset, :email))
    else
      {:error, changeset}
    end
  end

  defp do_get_or_create_account(repo, email) do
    timestamp = now()

    repo.insert_all(
      Account,
      [%{email: email, inserted_at: timestamp, updated_at: timestamp}],
      on_conflict: :nothing,
      conflict_target: :email
    )

    case repo.get_by(Account, email: email) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :account_not_found}
    end
  end

  defp put_chat_history_store_id(%{session_id: session_id} = attrs) when is_binary(session_id) do
    session =
      Session
      |> where([session], session.session_id == ^session_id)
      |> where([session], is_nil(session.archived_at))
      |> Repo.one()

    case session do
      %Session{store_id: store_id} -> Map.put(attrs, :store_id, store_id)
      nil -> attrs
    end
  end

  defp put_chat_history_store_id(attrs), do: attrs

  defp default_store_name(session_id), do: "Store for #{session_id}"

  defp normalize_user_id(user_id), do: Account.normalize_email(user_id)

  defp session_id_from(attrs) do
    Map.get(attrs, :session_id)
  end

  defp active_session_query(account_id, session_id) do
    Session
    |> where([session], session.account_id == ^account_id)
    |> where([session], session.session_id == ^session_id)
    |> where([session], is_nil(session.archived_at))
  end

  defp lock_active_session(repo, account_id, session_id) do
    case active_session_query(account_id, session_id) |> lock("FOR UPDATE") |> repo.one() do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  defp lock_restorable_session(repo, account_id, session_id, current_time) do
    query =
      Session
      |> where([session], session.account_id == ^account_id)
      |> where([session], session.session_id == ^session_id)
      |> where([session], not is_nil(session.archived_at))
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Session{purge_at: purge_at} = session ->
        if DateTime.compare(purge_at, current_time) == :gt,
          do: {:ok, session},
          else: {:error, :purge_deadline_passed}

      nil ->
        {:error, :not_found}
    end
  end

  defp lock_assignment_store(repo, account_id, store_id, session_id) do
    with {:ok, store} <- lock_store(repo, account_id, store_id, false),
         false <- store_has_other_non_archived_session?(repo, store.id, session_id) do
      {:ok, store}
    else
      true -> {:error, :store_occupied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_store(repo, account_id, store_id, archived?) do
    archive_filter =
      if archived?,
        do: dynamic([store], not is_nil(store.archived_at)),
        else: dynamic([store], is_nil(store.archived_at))

    query =
      Store
      |> where([store], store.id == ^store_id and store.account_id == ^account_id)
      |> where(^archive_filter)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Store{} = store -> {:ok, store}
      nil -> {:error, :not_found}
    end
  end

  defp store_has_non_archived_session?(repo, store_id) do
    Session
    |> where([session], session.store_id == ^store_id and is_nil(session.archived_at))
    |> repo.exists?()
  end

  defp store_has_other_non_archived_session?(repo, store_id, session_id) do
    Session
    |> where(
      [session],
      session.store_id == ^store_id and session.id != ^session_id and
        is_nil(session.archived_at)
    )
    |> repo.exists?()
  end

  defp update_source_store_after_move(
         _repo,
         %{session: %{store_id: store_id}, target_store: %{id: store_id}, source_store: store}
       ),
       do: {:ok, store}

  defp update_source_store_after_move(repo, %{source_store: store}),
    do: update_store_status(repo, store, "unassigned")

  defp update_store_status(repo, store, status) do
    store
    |> Store.update_changeset(%{status: status})
    |> repo.update()
  end

  defp discard_session_store(repo, store, true) do
    case repo.delete(store) do
      {:ok, _store} -> {:ok, :deleted}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp discard_session_store(repo, store, false),
    do: update_store_status(repo, store, "unassigned")

  defp multi_result({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp multi_result({:error, _operation, reason, _changes}, _key), do: {:error, reason}

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
