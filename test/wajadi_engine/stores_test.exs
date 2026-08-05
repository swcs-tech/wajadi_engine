defmodule WajadiEngine.StoresTest do
  use WajadiEngine.DataCase

  import WajadiEngine.AccountsFixtures

  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Personality
  alias WajadiEngine.Stores.Product

  describe "store ownership" do
    test "normal reads and writes are account scoped" do
      account = account_fixture()
      other_account = account_fixture()
      store = store_fixture(account)

      assert {:ok, ^store} = Stores.fetch_store(account, store.id)
      assert {:error, :not_found} = Stores.fetch_store(other_account, store.id)
      assert {:error, :not_found} = Stores.update_store(other_account, store.id, %{name: "Nope"})
    end

    test "archives only unassigned stores and restores before deadline" do
      account = account_fixture()
      store = store_fixture(account)
      archived_at = ~U[2026-01-01 00:00:00.000000Z]

      assert {:ok, archived} = Stores.archive_store(account, store.id, archived_at)
      assert archived.status == "archived"
      assert archived.purge_at == ~U[2026-04-01 00:00:00.000000Z]
      assert {:error, :not_found} = Stores.fetch_store(account, store.id)

      assert {:ok, restored} =
               Stores.restore_store(account, store.id, ~U[2026-03-31 23:59:59.000000Z])

      assert restored.status == "unassigned"
      assert is_nil(restored.archived_at)
      assert is_nil(restored.purge_at)
    end

    test "rejects archiving a store with a non-archived session" do
      session = session_fixture()
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)

      assert {:error, :store_in_use} = Stores.archive_store(account, session.store_id)
    end
  end

  describe "personality" do
    test "upserts one personality per store and returns a default when absent" do
      account = account_fixture()
      store = store_fixture(account)

      assert {:ok, default} = Stores.get_effective_personality(account, store.id)
      assert default =~ "admin toko Wajadi"

      assert {:ok, personality} =
               Stores.upsert_personality(account, store.id, %{prompt: "  Friendly specialist  "})

      assert personality.prompt == "Friendly specialist"
      assert {:ok, "Friendly specialist"} = Stores.get_effective_personality(account, store.id)

      assert {:ok, updated} =
               Stores.upsert_personality(account, store.id, %{prompt: "Updated specialist"})

      assert updated.prompt == "Updated specialist"

      assert Repo.aggregate(
               from(personality in Personality, where: personality.store_id == ^store.id),
               :count
             ) == 1
    end

    test "rejects blank prompts and cross-account access" do
      account = account_fixture()
      other_account = account_fixture()
      store = store_fixture(account)

      assert {:error, changeset} = Stores.upsert_personality(account, store.id, %{prompt: " "})
      assert %{prompt: ["can't be blank"]} = errors_on(changeset)

      assert {:error, :not_found} =
               Stores.upsert_personality(other_account, store.id, %{prompt: "Stolen"})
    end
  end

  describe "products" do
    test "orders active products deterministically and archives without deletion" do
      account = account_fixture()
      store = store_fixture(account)
      second = product_fixture(account, store, %{name: "B", sort_order: 1})
      first = product_fixture(account, store, %{name: "A", sort_order: 1})
      archived = product_fixture(account, store, %{name: "Archived", sort_order: 0})
      assert {:ok, _archived} = Stores.archive_product(account, store.id, archived.id)

      assert {:ok, products} = Stores.list_products(account, store.id)
      assert Enum.map(products, & &1.id) == [first.id, second.id]
      assert Repo.get!(Product, archived.id).is_active == false
    end

    test "enforces SKU uniqueness per store and permits same SKU across stores" do
      account = account_fixture()
      first_store = store_fixture(account)
      second_store = store_fixture(account)
      _first = product_fixture(account, first_store, %{sku: " same-sku "})

      assert {:error, changeset} =
               Stores.create_product(account, first_store.id, %{
                 name: "Duplicate",
                 sku: "SAME-SKU",
                 price: "1.00",
                 availability: "unknown"
               })

      assert %{sku: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, product} =
               Stores.create_product(account, second_store.id, %{
                 name: "Allowed",
                 sku: "SAME-SKU",
                 price: "1.00",
                 availability: "unknown"
               })

      assert product.sku == "SAME-SKU"
    end

    test "validates non-negative values, availability, and optional stock" do
      account = account_fixture()
      store = store_fixture(account)

      assert {:ok, product} =
               Stores.create_product(account, store.id, %{
                 name: "Unknown stock",
                 price: "0.00",
                 stock_quantity: nil,
                 availability: "unknown"
               })

      assert is_nil(product.stock_quantity)

      assert {:error, changeset} =
               Stores.create_product(account, store.id, %{
                 name: "Invalid",
                 price: "-1.00",
                 stock_quantity: -1,
                 availability: "missing",
                 sort_order: -1
               })

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :price)
      assert Map.has_key?(errors, :stock_quantity)
      assert Map.has_key?(errors, :availability)
      assert Map.has_key?(errors, :sort_order)
    end
  end
end
