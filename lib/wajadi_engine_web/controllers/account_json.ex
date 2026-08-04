defmodule WajadiEngineWeb.AccountJSON do
  @moduledoc """
  JSON rendering for account management API responses.
  """

  alias WajadiEngine.Stores.Personality
  alias WajadiEngine.Stores.Product
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp.Session

  def success(%{message: message, data: data}) do
    %{success: true, status: "success", message: message, data: data}
  end

  def error(%{message: message, error: error}) do
    %{success: false, status: "error", message: message, error: error}
  end

  def stores(%{stores: stores}), do: %{stores: Enum.map(stores, &store/1)}
  def store(%Store{} = store), do: render_store(store)
  def personality(%Personality{} = personality), do: render_personality(personality)
  def personality(%{prompt: prompt}), do: %{prompt: prompt}
  def products(%{products: products}), do: %{products: Enum.map(products, &product/1)}
  def product(%Product{} = product), do: render_product(product)
  def session(%Session{} = session), do: render_session(session)

  def restored_session(%Session{} = session) do
    session
    |> render_session()
    |> Map.put(:requires_qr_pairing, true)
  end

  defp render_store(%Store{} = store) do
    %{
      id: store.id,
      account_id: store.account_id,
      name: store.name,
      status: store.status,
      archived_at: store.archived_at,
      purge_at: store.purge_at,
      created_at: store.inserted_at,
      updated_at: store.updated_at
    }
  end

  defp render_personality(%Personality{} = personality) do
    %{
      id: personality.id,
      store_id: personality.store_id,
      prompt: personality.prompt,
      created_at: personality.inserted_at,
      updated_at: personality.updated_at
    }
  end

  defp render_product(%Product{} = product) do
    %{
      id: product.id,
      store_id: product.store_id,
      name: product.name,
      sku: product.sku,
      description: product.description,
      price: decimal_to_string(product.price),
      currency: product.currency,
      stock_quantity: product.stock_quantity,
      availability: product.availability,
      image_url: product.image_url,
      is_active: product.is_active,
      sort_order: product.sort_order,
      created_at: product.inserted_at,
      updated_at: product.updated_at
    }
  end

  defp render_session(%Session{} = session) do
    %{
      session_id: session.session_id,
      account_id: session.account_id,
      store_id: session.store_id,
      user_id: session.user_id,
      phone_number: session.phone_number,
      status: session.status,
      is_active: session.is_active,
      archived_at: session.archived_at,
      purge_at: session.purge_at,
      created_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp decimal_to_string(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp decimal_to_string(nil), do: nil
end
