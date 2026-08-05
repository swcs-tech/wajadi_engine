defmodule WajadiEngine.Stores.Product do
  use Ecto.Schema

  import Ecto.Changeset

  alias WajadiEngine.Stores.Store

  @availabilities ~w(unknown in_stock out_of_stock preorder)
  @currencies ~w(IDR USD EUR SGD MYR)

  @type availability :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          store_id: integer() | nil,
          name: String.t() | nil,
          sku: String.t() | nil,
          description: String.t() | nil,
          price: Decimal.t() | nil,
          currency: String.t(),
          stock_quantity: non_neg_integer() | nil,
          availability: availability(),
          image_url: String.t() | nil,
          is_active: boolean(),
          sort_order: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "store_products" do
    field :name, :string
    field :sku, :string
    field :description, :string
    field :price, :decimal
    field :currency, :string, default: "IDR"
    field :stock_quantity, :integer
    field :availability, :string, default: "unknown"
    field :image_url, :string
    field :is_active, :boolean, default: true
    field :sort_order, :integer, default: 0

    belongs_to :store, Store

    timestamps(type: :utc_datetime_usec)
  end

  @spec availabilities() :: [availability()]
  def availabilities, do: @availabilities

  @spec create_changeset(t(), Store.t(), map()) :: Ecto.Changeset.t()
  def create_changeset(product, %Store{id: store_id}, attrs) when is_map(attrs) do
    product
    |> cast_product(attrs)
    |> put_change(:store_id, store_id)
    |> validate_product()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(product, attrs) when is_map(attrs) do
    product
    |> cast_product(attrs)
    |> validate_product()
  end

  @spec archive_changeset(t()) :: Ecto.Changeset.t()
  def archive_changeset(product), do: change(product, is_active: false)

  defp cast_product(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :sku,
      :description,
      :price,
      :currency,
      :stock_quantity,
      :availability,
      :image_url,
      :is_active,
      :sort_order
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:sku, &normalize_optional(&1, :upcase))
    |> update_change(:description, &normalize_optional(&1, :preserve))
    |> update_change(:currency, &(String.trim(&1) |> String.upcase()))
    |> update_change(:image_url, &normalize_optional(&1, :preserve))
  end

  defp validate_product(changeset) do
    changeset
    |> validate_required([
      :store_id,
      :name,
      :price,
      :currency,
      :availability,
      :is_active,
      :sort_order
    ])
    |> validate_length(:name, max: 200)
    |> validate_length(:sku, max: 100)
    |> validate_length(:description, max: 4_000)
    |> validate_length(:currency, is: 3)
    |> validate_inclusion(:currency, @currencies)
    |> validate_inclusion(:availability, @availabilities)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:stock_quantity, greater_than_or_equal_to: 0)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_change(:image_url, &validate_image_url/2)
    |> unique_constraint(:sku, name: :store_products_store_id_sku_index)
    |> foreign_key_constraint(:store_id)
    |> check_constraint(:name, name: :store_products_name_not_blank)
    |> check_constraint(:price, name: :store_products_price_non_negative)
    |> check_constraint(:stock_quantity, name: :store_products_stock_non_negative)
    |> check_constraint(:sort_order, name: :store_products_sort_order_non_negative)
    |> check_constraint(:availability, name: :store_products_availability_check)
  end

  defp validate_image_url(:image_url, value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) ->
        []

      _other ->
        [image_url: "must be an absolute HTTPS URL"]
    end
  end

  defp normalize_optional(nil, _casing), do: nil

  defp normalize_optional(value, casing) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value when casing == :upcase -> String.upcase(value)
      value -> value
    end
  end
end
