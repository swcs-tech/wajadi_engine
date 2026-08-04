defmodule WajadiEngine.Stores.Personality do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Stores.Store

  @max_prompt_length 4_000

  @type t :: %__MODULE__{
          id: integer() | nil,
          store_id: integer() | nil,
          prompt: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "store_personalities" do
    field :prompt, :string

    belongs_to :store, Store

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), Store.t(), map()) :: Ecto.Changeset.t()
  def changeset(personality, %Store{id: store_id}, attrs) when is_map(attrs) do
    personality
    |> cast(attrs, [:prompt])
    |> update_change(:prompt, &String.trim/1)
    |> put_change(:store_id, store_id)
    |> validate_required([:store_id, :prompt])
    |> validate_length(:prompt, max: @max_prompt_length)
    |> unique_constraint(:store_id, name: :store_personalities_store_id_index)
    |> foreign_key_constraint(:store_id)
    |> check_constraint(:prompt, name: :store_personalities_prompt_not_blank)
  end
end
