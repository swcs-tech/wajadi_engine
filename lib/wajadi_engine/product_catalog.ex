defmodule WajadiEngine.ProductCatalog do
  @moduledoc """
  Read-only, store-scoped product catalog boundary for AI auto-replies.
  """

  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Product

  @generic_query_tokens ~w(
    ada apa apakah saja product produk katalog menu list daftar barang tersedia
    stok harga saya mau ingin cari lihat tampilkan tunjukkan info informasi punya boleh bisa
    dong ya yang tentang foto fotonya gambar image photo picture pict kirim kirimkan minta tolong min kak kakak
  )
  @image_request_tokens ~w(foto gambar image photo picture pict)

  @type product :: %{
          required(:id) => integer(),
          required(:name) => String.t(),
          required(:price) => Decimal.t(),
          required(:currency) => String.t(),
          required(:stock_quantity) => non_neg_integer() | nil,
          required(:availability) => Product.availability(),
          optional(:sku) => String.t(),
          optional(:description) => String.t(),
          optional(:image_url) => String.t()
        }

  @type product_list :: %{products: [product()], total: non_neg_integer()}

  @spec list_products(integer(), integer()) :: [product()]
  def list_products(account_id, store_id)
      when is_integer(account_id) and is_integer(store_id) do
    case Stores.list_products(account_id, store_id) do
      {:ok, products} -> Enum.map(products, &to_product/1)
      {:error, :not_found} -> []
    end
  end

  @spec search_products(integer(), integer(), nil | String.t()) :: [product()]
  def search_products(account_id, store_id, query \\ nil)
      when is_integer(account_id) and is_integer(store_id) do
    products = list_products(account_id, store_id)

    case query_terms(query) do
      [] -> products
      terms -> Enum.filter(products, &matches_query?(&1, terms))
    end
  end

  @spec image_request?(String.t()) :: boolean()
  def image_request?(query) when is_binary(query) do
    query
    |> tokens()
    |> Enum.any?(&(&1 in @image_request_tokens))
  end

  def image_request?(_query), do: false

  @spec structured_products([product()]) :: product_list()
  def structured_products(products) when is_list(products) do
    %{products: products, total: length(products)}
  end

  @spec product_image_url(product()) :: String.t() | nil
  def product_image_url(product) when is_map(product) do
    product
    |> field(:image_url)
    |> normalize_optional_string()
  end

  @spec product_caption(product()) :: String.t()
  def product_caption(product) when is_map(product) do
    [field(product, :name), format_price(product), optional_field(product, :description)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
  end

  @spec encode_products([product()]) :: String.t()
  def encode_products(products) when is_list(products) do
    products
    |> structured_products()
    |> encode_decimals()
    |> Jason.encode!()
  end

  @spec format_products([product()]) :: String.t()
  def format_products([]), do: "Belum ada product yang tersedia saat ini."

  def format_products(products) when is_list(products) do
    products
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {product, index} -> format_product(product, index) end)
  end

  defp to_product(%Product{} = product) do
    %{
      id: product.id,
      name: product.name,
      sku: product.sku,
      description: product.description,
      price: product.price,
      currency: product.currency,
      stock_quantity: product.stock_quantity,
      availability: product.availability,
      image_url: product.image_url
    }
  end

  defp encode_decimals(%{products: products} = catalog) do
    encoded_products =
      Enum.map(products, fn product ->
        Map.update!(product, :price, &Decimal.to_string(&1, :normal))
      end)

    %{catalog | products: encoded_products}
  end

  defp format_product(product, index) do
    [
      "#{index}. #{field(product, :name)}",
      format_price(product),
      format_availability(product),
      optional_field(product, :description)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" - ")
  end

  defp format_price(product) do
    case {field(product, :price), field(product, :currency)} do
      {%Decimal{} = price, "IDR"} ->
        "Rp#{format_decimal(price)}"

      {%Decimal{} = price, currency} when is_binary(currency) ->
        "#{currency} #{Decimal.to_string(price, :normal)}"

      _other ->
        ""
    end
  end

  defp format_availability(product) do
    case {field(product, :availability), field(product, :stock_quantity)} do
      {"out_of_stock", _stock} -> "Stok: habis"
      {_availability, 0} -> "Stok: habis"
      {"preorder", _stock} -> "Status: preorder"
      {"available", stock} when is_integer(stock) -> "Stok: #{stock}"
      {"available", nil} -> "Stok: tersedia"
      {"unknown", _stock} -> "Stok: belum diketahui"
      {_availability, stock} when is_integer(stock) -> "Stok: #{stock}"
      _other -> ""
    end
  end

  defp format_decimal(decimal) do
    decimal
    |> Decimal.to_string(:normal)
    |> String.split(".", parts: 2)
    |> case do
      [integer] -> group_thousands(integer)
      [integer, "00"] -> group_thousands(integer)
      [integer, fraction] -> "#{group_thousands(integer)},#{String.trim_trailing(fraction, "0")}"
    end
  end

  defp group_thousands(amount) do
    amount
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(".", &Enum.join/1)
  end

  defp matches_query?(product, terms) do
    searchable_text =
      [field(product, :name), field(product, :sku), field(product, :description)]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.all?(terms, &String.contains?(searchable_text, &1))
  end

  defp query_terms(query) do
    query
    |> tokens()
    |> Enum.reject(&(&1 in @generic_query_tokens))
  end

  defp tokens(query) do
    query
    |> normalize_query()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp normalize_query(query) when is_binary(query), do: String.downcase(query)
  defp normalize_query(_query), do: ""

  defp optional_field(product, field_name) do
    product
    |> field(field_name)
    |> normalize_optional_string()
    |> Kernel.||("")
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp field(product, field_name) do
    Map.get(product, field_name) || Map.get(product, Atom.to_string(field_name))
  end
end
