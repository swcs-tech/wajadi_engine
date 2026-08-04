defmodule WajadiEngine.Accounts.Account do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp.Session

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "accounts" do
    field :email, :string

    has_many :stores, Store
    has_many :sessions, Session

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(account, attrs) do
    account
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_length(:email, max: 320)
    |> unique_constraint(:email, name: :accounts_email_index)
  end

  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  def normalize_email(nil), do: nil
end
