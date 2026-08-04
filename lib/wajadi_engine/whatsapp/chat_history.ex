defmodule WajadiEngine.WhatsApp.ChatHistory do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Stores.Store

  @statuses ~w(received sent failed)

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          store_id: integer() | nil,
          session_id: String.t() | nil,
          from: String.t() | nil,
          to: String.t() | nil,
          from_me: boolean(),
          body: String.t() | nil,
          type: String.t(),
          status: status() | nil,
          error: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "wa_chat_histories" do
    belongs_to :store, Store

    field :session_id, :string
    field :from, :string
    field :to, :string
    field :from_me, :boolean, default: false
    field :body, :string
    field :type, :string, default: "text"
    field :status, :string
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(chat_history, attrs) do
    chat_history
    |> cast(attrs, [:store_id, :session_id, :from, :to, :from_me, :body, :type, :status, :error])
    |> validate_required([:store_id, :session_id, :from, :to, :from_me, :body, :type, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:store_id)
  end
end
