# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     WajadiEngine.Repo.insert!(%WajadiEngine.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

if Mix.env() in [:dev, :test] and System.get_env("WAJADI_SEED_DEMO_DATA") == "true" do
  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.WhatsApp

  email = "owner@example.com"

  account =
    case Repo.get_by(Account, email: email) do
      %Account{} = account ->
        account

      nil ->
        %Account{}
        |> Account.create_changeset(%{email: email})
        |> Repo.insert!()
    end

  store =
    account
    |> Stores.list_stores()
    |> Enum.find(&(&1.name == "Wajadi Demo Store"))
    |> case do
      nil ->
        {:ok, store} = Stores.create_store(account, %{name: "Wajadi Demo Store"})
        store

      store ->
        store
    end

  {:ok, _personality} =
    Stores.upsert_personality(account, store.id, %{
      prompt: "Use a friendly, concise Indonesian tone for the demo store."
    })

  existing_skus =
    account
    |> Stores.list_products(store.id)
    |> case do
      {:ok, products} -> MapSet.new(products, & &1.sku)
      {:error, :not_found} -> MapSet.new()
    end

  for attrs <- [
        %{
          name: "Kopi Arabica 250g",
          sku: "DEMO-ARABICA-250G",
          description: "Fruity coffee with light acidity.",
          price: "75000.00",
          currency: "IDR",
          stock_quantity: 10,
          availability: "in_stock",
          sort_order: 1
        },
        %{
          name: "Kopi Robusta 250g",
          sku: "DEMO-ROBUSTA-250G",
          description: "Bold body with balanced chocolate bitterness.",
          price: "55000.00",
          currency: "IDR",
          stock_quantity: 8,
          availability: "in_stock",
          sort_order: 2
        }
      ],
      not MapSet.member?(existing_skus, attrs.sku) do
    {:ok, _product} = Stores.create_product(account, store.id, attrs)
  end

  if is_nil(WhatsApp.get_session("demo-session")) and store.status == "unassigned" do
    {:ok, _session} =
      WhatsApp.create_session(account.email, %{session_id: "demo-session", store_id: store.id})
  end
end
