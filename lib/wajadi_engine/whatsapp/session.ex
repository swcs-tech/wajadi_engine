defmodule WajadiEngine.WhatsApp.Session do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Stores.Store

  @statuses ~w(connecting qr connected disconnected paused)

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          account_id: integer() | nil,
          store_id: integer() | nil,
          user_id: String.t() | nil,
          session_id: String.t() | nil,
          phone_number: String.t() | nil,
          status: status(),
          qr: String.t() | nil,
          is_active: boolean(),
          last_connected_at: DateTime.t() | nil,
          last_disconnected_at: DateTime.t() | nil,
          last_qr_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          purge_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "wa_sessions" do
    belongs_to :account, Account
    belongs_to :store, Store

    field :user_id, :string
    field :session_id, :string
    field :phone_number, :string
    field :status, :string, default: "disconnected"
    field :qr, :string
    field :is_active, :boolean, default: false
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_qr_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :purge_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec create_changeset(t(), Account.t(), Store.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(
        session,
        %Account{id: account_id, email: email},
        %Store{id: store_id},
        attrs
      ) do
    session
    |> cast(attrs, [
      :session_id,
      :phone_number,
      :status,
      :qr,
      :is_active,
      :last_connected_at,
      :last_disconnected_at,
      :last_qr_at
    ])
    |> put_change(:account_id, account_id)
    |> put_change(:store_id, store_id)
    |> put_change(:user_id, email)
    |> validate_required([:account_id, :store_id, :user_id, :session_id, :status, :is_active])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
    |> unique_constraint(:store_id, name: :wa_sessions_one_non_archived_session_per_store_index)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:store_id)
    |> check_constraint(:status, name: :wa_sessions_status_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :phone_number,
      :status,
      :qr,
      :is_active,
      :last_connected_at,
      :last_disconnected_at,
      :last_qr_at,
      :archived_at,
      :purge_at
    ])
    |> validate_required([:status, :is_active])
    |> validate_inclusion(:status, @statuses)
    |> validate_archive_window()
    |> unique_constraint(:store_id, name: :wa_sessions_one_non_archived_session_per_store_index)
    |> check_constraint(:status, name: :wa_sessions_status_check)
    |> check_constraint(:purge_at, name: :wa_sessions_archive_window_check)
  end

  @spec assignment_changeset(t(), Store.t()) :: Ecto.Changeset.t()
  def assignment_changeset(session, %Store{id: store_id}) do
    session
    |> change(store_id: store_id)
    |> unique_constraint(:store_id, name: :wa_sessions_one_non_archived_session_per_store_index)
    |> foreign_key_constraint(:store_id)
  end

  @spec archive_changeset(t(), DateTime.t(), DateTime.t()) :: Ecto.Changeset.t()
  def archive_changeset(session, archived_at, purge_at) do
    update_changeset(session, %{
      status: "disconnected",
      is_active: false,
      qr: nil,
      archived_at: archived_at,
      purge_at: purge_at,
      last_disconnected_at: archived_at
    })
  end

  @spec restore_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def restore_changeset(session, restored_at) do
    update_changeset(session, %{
      status: "disconnected",
      is_active: false,
      qr: nil,
      archived_at: nil,
      purge_at: nil,
      last_disconnected_at: restored_at
    })
  end

  defp validate_archive_window(changeset) do
    archived_at = get_field(changeset, :archived_at)
    purge_at = get_field(changeset, :purge_at)

    case {archived_at, purge_at} do
      {nil, nil} ->
        changeset

      {%DateTime{} = archived_at, %DateTime{} = purge_at} ->
        validate_purge_after_archive(changeset, archived_at, purge_at)

      {nil, %DateTime{}} ->
        add_error(changeset, :archived_at, "must be set when purge_at is set")

      {%DateTime{}, nil} ->
        add_error(changeset, :purge_at, "must be set when archived_at is set")
    end
  end

  defp validate_purge_after_archive(changeset, archived_at, purge_at) do
    if DateTime.compare(purge_at, archived_at) == :gt do
      changeset
    else
      add_error(changeset, :purge_at, "must be after archived_at")
    end
  end
end
