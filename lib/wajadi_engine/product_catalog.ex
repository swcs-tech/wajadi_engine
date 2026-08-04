defmodule WajadiEngine.ProductCatalog do
  @moduledoc """
  Read-only product catalog boundary for AI auto-replies.
  """

  @generic_query_tokens ~w(
    ada apa apakah saja product produk katalog menu list daftar barang tersedia
    stok harga saya mau ingin cari lihat tampilkan tunjukkan info informasi punya boleh bisa
    dong ya yang tentang foto fotonya gambar image photo picture pict kirim kirimkan minta tolong min kak kakak
  )

  @image_request_tokens ~w(foto gambar image photo picture pict)

  @type product :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:price) => non_neg_integer(),
          required(:currency) => String.t(),
          required(:stock_quantity) => non_neg_integer(),
          optional(:description) => String.t(),
          optional(:image_url) => String.t()
        }

  @type product_list :: %{products: [product()], total: non_neg_integer()}

  @spec list_products() :: [product()]
  def list_products do
    :wajadi_engine
    |> Application.get_env(:product_catalog, [])
    |> Keyword.get(:products, [])
    |> Enum.filter(&valid_product?/1)
  end

  @spec search_products(nil | String.t()) :: [product()]
  def search_products(query \\ nil) do
    products = list_products()

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
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
    |> case do
      "" -> nil
      value -> value
    end
  end

  @spec product_caption(product()) :: String.t()
  def product_caption(product) when is_map(product) do
    [field(product, :name), format_price(product), optional_field(product, :description)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
  end

  @spec encode_products([product()]) :: String.t()
  def encode_products(products \\ list_products()) do
    products
    |> structured_products()
    |> Jason.encode!()
  end

  @spec format_products([product()]) :: String.t()
  def format_products(products \\ list_products()) do
    case products do
      [] ->
        "Belum ada product yang tersedia saat ini."

      products ->
        products
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {product, index} -> format_product(product, index) end)
    end
  end

  defp valid_product?(product) when is_map(product) do
    present?(field(product, :id)) and
      present?(field(product, :name)) and
      non_negative_integer?(field(product, :price)) and
      present?(field(product, :currency)) and
      non_negative_integer?(field(product, :stock_quantity))
  end

  defp valid_product?(_product), do: false

  defp format_product(product, index) do
    [
      "#{index}. #{field(product, :name)}",
      format_price(product),
      format_stock(product),
      optional_field(product, :description)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" - ")
  end

  defp format_price(product) do
    case {field(product, :price), field(product, :currency)} do
      {price, "IDR"} when is_integer(price) -> "Rp#{format_amount(price)}"
      {price, currency} when is_integer(price) and is_binary(currency) -> "#{currency} #{price}"
      _ -> ""
    end
  end

  defp format_stock(product) do
    case field(product, :stock_quantity) do
      stock when is_integer(stock) and stock > 0 -> "Stok: tersedia"
      0 -> "Stok: habis"
      _ -> ""
    end
  end

  defp format_amount(amount) do
    amount
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(".", &Enum.join/1)
  end

  defp matches_query?(product, terms) do
    searchable_text =
      [field(product, :name), field(product, :description)]
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
    |> case do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp field(product, field_name) do
    Map.get(product, field_name) || Map.get(product, Atom.to_string(field_name))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
