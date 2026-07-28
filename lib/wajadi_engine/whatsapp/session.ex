defmodule WajadiEngine.WhatsApp.Session do
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(connecting qr connected disconnected paused)

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: String.t() | nil,
          session_id: String.t() | nil,
          phone_number: String.t() | nil,
          status: status(),
          qr: String.t() | nil,
          is_active: boolean(),
          last_connected_at: DateTime.t() | nil,
          last_disconnected_at: DateTime.t() | nil,
          last_qr_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "wa_sessions" do
    field :user_id, :string
    field :session_id, :string
    field :phone_number, :string
    field :status, :string, default: "disconnected"
    field :qr, :string
    field :is_active, :boolean, default: false
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_qr_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :session_id,
      :phone_number,
      :status,
      :qr,
      :is_active,
      :last_connected_at,
      :last_disconnected_at,
      :last_qr_at
    ])
    |> validate_required([:user_id, :session_id, :status, :is_active])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
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
      :last_qr_at
    ])
    |> validate_required([:status, :is_active])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :wa_sessions_status_check)
  end
end
