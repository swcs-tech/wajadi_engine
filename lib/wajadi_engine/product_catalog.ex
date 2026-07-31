defmodule WajadiEngine.ProductCatalog do
  @moduledoc """
  Read-only product catalog boundary for AI auto-replies.
  """

  @type product :: %{
          optional(:name) => String.t(),
          optional(:price) => String.t(),
          optional(:stock) => String.t(),
          optional(:description) => String.t()
        }

  @spec list_products() :: [product()]
  def list_products do
    :wajadi_engine
    |> Application.get_env(:product_catalog, [])
    |> Keyword.get(:products, [])
    |> Enum.filter(&valid_product?/1)
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
    product
    |> field(:name)
    |> present?()
  end

  defp valid_product?(_product), do: false

  defp format_product(product, index) do
    [
      "#{index}. #{field(product, :name)}",
      optional_field(product, :price),
      optional_field(product, :stock),
      optional_field(product, :description)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" - ")
  end

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
end
