defmodule WajadiEngine.Stores.Store do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Stores.Personality
  alias WajadiEngine.Stores.Product
  alias WajadiEngine.WhatsApp.ChatHistory
  alias WajadiEngine.WhatsApp.Session

  @statuses ~w(active unassigned archived)

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          account_id: integer() | nil,
          name: String.t() | nil,
          status: status(),
          archived_at: DateTime.t() | nil,
          purge_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "stores" do
    field :name, :string
    field :status, :string, default: "active"
    field :archived_at, :utc_datetime_usec
    field :purge_at, :utc_datetime_usec

    belongs_to :account, Account
    has_one :personality, Personality
    has_many :products, Product
    has_many :sessions, Session
    has_many :chat_histories, ChatHistory

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec create_changeset(t(), Account.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(store, %Account{id: account_id}, attrs) when is_map(attrs) do
    create_changeset(store, %Account{id: account_id}, attrs, "unassigned")
  end

  @spec create_changeset(t(), Account.t(), map(), status()) :: Ecto.Changeset.t()
  def create_changeset(store, %Account{id: account_id}, attrs, status)
      when is_map(attrs) and status in @statuses do
    store
    |> cast(attrs, [:name])
    |> put_change(:account_id, account_id)
    |> put_change(:status, status)
    |> validate_required([:account_id, :name, :status])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:account_id)
    |> check_constraint(:status, name: :stores_status_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(store, attrs) do
    store
    |> cast(attrs, [:name, :status, :archived_at, :purge_at])
    |> validate_required([:name, :status])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_inclusion(:status, @statuses)
    |> validate_archive_window()
    |> check_constraint(:status, name: :stores_status_check)
    |> check_constraint(:purge_at, name: :stores_archive_window_check)
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
