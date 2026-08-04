defmodule WajadiEngine.AccountsFixturesTest do
  use WajadiEngine.DataCase, async: true

  import WajadiEngine.AccountsFixtures

  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.Session

  test "two_accounts_fixture creates isolated accounts and stores" do
    fixtures = two_accounts_fixture()

    assert fixtures.first_account.id != fixtures.second_account.id
    assert [_first_store, _second_store] = fixtures.first_stores
    assert [_other_store] = fixtures.second_stores
    assert Enum.all?(fixtures.first_stores, &(&1.account_id == fixtures.first_account.id))
    assert Enum.all?(fixtures.second_stores, &(&1.account_id == fixtures.second_account.id))
  end

  test "personality and product fixtures use store-scoped contexts" do
    account = account_fixture()
    store = store_fixture(account)

    personality = personality_fixture(account, store, %{prompt: "  Custom prompt  "})
    product = product_fixture(account, store, %{sku: " abc-1 "})
    archived_product = archived_product_fixture(account, store, %{sku: " archived-1 "})

    assert personality.store_id == store.id
    assert personality.prompt == "Custom prompt"
    assert product.store_id == store.id
    assert product.sku == "ABC-1"
    assert archived_product.is_active == false

    assert {:ok, products} = Stores.list_products(account, store.id)
    refute Enum.any?(products, &(&1.id == archived_product.id))
  end

  test "session lifecycle fixtures create moved and archived states" do
    moved = moved_session_fixture("owner@example.com")
    restorable = restorable_session_fixture("restorable@example.com")
    expired = expired_session_fixture("expired@example.com")

    assert moved.session.store_id == moved.target_store.id
    assert Repo.get!(WajadiEngine.Stores.Store, moved.source_store.id).status == "unassigned"
    assert restorable.session.archived_at
    assert DateTime.compare(restorable.session.purge_at, DateTime.utc_now()) == :gt
    assert expired.session.archived_at
    assert DateTime.compare(expired.session.purge_at, DateTime.utc_now()) == :lt

    assert {:error, :not_found} =
             WhatsApp.fetch_session_for_account(restorable.account, restorable.session.session_id)

    assert %Session{} = Repo.get!(Session, restorable.session.id)
  end

  test "fixtures do not mutate global product or personality config" do
    product_config = Application.get_env(:wajadi_engine, :product_catalog)
    ai_agent_config = Application.get_env(:wajadi_engine, :ai_agent)

    account = account_fixture()
    store = store_fixture(account)
    _personality = personality_fixture(account, store)
    _product = product_fixture(account, store)

    assert Application.get_env(:wajadi_engine, :product_catalog) == product_config
    assert Application.get_env(:wajadi_engine, :ai_agent) == ai_agent_config
  end
end
