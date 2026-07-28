defmodule WajadiEngine.WhatsApp.AuthState do
  use Ecto.Schema

  import Ecto.Changeset

  @encodings ~w(json erlang_term_base64)

  @type encoding :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          session_id: String.t() | nil,
          type: String.t() | nil,
          key: String.t() | nil,
          value: map() | nil,
          encoding: encoding(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "wa_auth_states" do
    field :session_id, :string
    field :type, :string
    field :key, :string
    field :value, :map
    field :encoding, :string, default: "json"

    timestamps(type: :utc_datetime_usec)
  end

  @spec encodings() :: [encoding()]
  def encodings, do: @encodings

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(auth_state, attrs) do
    auth_state
    |> cast(attrs, [:session_id, :type, :key, :value, :encoding])
    |> validate_required([:session_id, :type, :key, :value, :encoding])
    |> validate_inclusion(:encoding, @encodings)
    |> unique_constraint([:session_id, :type, :key])
    |> check_constraint(:encoding, name: :wa_auth_states_encoding_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(auth_state, attrs) do
    auth_state
    |> cast(attrs, [:value, :encoding])
    |> validate_required([:value, :encoding])
    |> validate_inclusion(:encoding, @encodings)
    |> check_constraint(:encoding, name: :wa_auth_states_encoding_check)
  end
end
