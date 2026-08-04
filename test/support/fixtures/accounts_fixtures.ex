defmodule WajadiEngine.AccountsFixtures do
  @moduledoc false

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.WhatsApp

  def account_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.merge(%{email: "owner-#{unique}@example.com"}, attrs)

    %Account{}
    |> Account.create_changeset(attrs)
    |> Repo.insert!()
  end

  def store_fixture(account, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.merge(%{name: "Store #{unique}"}, attrs)
    {:ok, store} = Stores.create_store(account, attrs)
    store
  end

  def product_fixture(account, store, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          name: "Product #{unique}",
          sku: "SKU-#{unique}",
          price: "10000.00",
          currency: "IDR",
          stock_quantity: 10,
          availability: "available",
          sort_order: 0
        },
        attrs
      )

    {:ok, product} = Stores.create_product(account, store.id, attrs)
    product
  end

  def session_fixture(user_id \\ nil, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    user_id = user_id || "owner-#{unique}@example.com"
    attrs = Map.put_new(attrs, :session_id, "session-#{unique}")
    {:ok, session} = WhatsApp.create_session(user_id, attrs)
    session
  end
end
