defmodule WajadiEngine.AccountsFixtures do
  @moduledoc false

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Store
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

  def account_with_stores_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account = account_fixture(Map.get(attrs, :account, %{}))
    stores = Map.get(attrs, :stores, [%{}, %{}])

    %{account: account, stores: Enum.map(stores, &store_fixture(account, &1))}
  end

  def two_accounts_fixture do
    first = account_with_stores_fixture(stores: [%{name: "First Store"}, %{name: "Second Store"}])
    second = account_with_stores_fixture(stores: [%{name: "Other Store"}])

    %{
      first_account: first.account,
      first_stores: first.stores,
      second_account: second.account,
      second_stores: second.stores
    }
  end

  def personality_fixture(account, store, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.merge(%{prompt: "Personality #{unique}"}, attrs)
    {:ok, personality} = Stores.upsert_personality(account, store.id, attrs)
    personality
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
          availability: "in_stock",
          sort_order: 0
        },
        attrs
      )

    {:ok, product} = Stores.create_product(account, store.id, attrs)
    product
  end

  def archived_product_fixture(account, store, attrs \\ %{}) do
    product = product_fixture(account, store, attrs)
    {:ok, product} = Stores.archive_product(account, store.id, product.id)
    product
  end

  def session_fixture(user_id \\ nil, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    user_id = user_id || "owner-#{unique}@example.com"
    attrs = Map.put_new(attrs, :session_id, "session-#{unique}")
    {:ok, session} = WhatsApp.create_session(user_id, attrs)
    session
  end

  def moved_session_fixture(user_id \\ nil) do
    session = session_fixture(user_id)
    account = Repo.get!(Account, session.account_id)
    source_store = Repo.get!(Store, session.store_id)

    target_store =
      store_fixture(account, %{name: "Move Target #{System.unique_integer([:positive])}"})

    {:ok, moved_session} = WhatsApp.move_session(account, session.session_id, target_store.id)

    %{
      account: account,
      source_store: source_store,
      target_store: target_store,
      session: moved_session
    }
  end

  def archived_session_fixture(user_id \\ nil, attrs \\ %{}, archived_at \\ nil) do
    session = session_fixture(user_id, attrs)
    account = Repo.get!(Account, session.account_id)
    archived_at = archived_at || default_restorable_archive_time()
    {:ok, archived_session} = WhatsApp.archive_session(account, session.session_id, archived_at)

    %{
      account: account,
      store: Repo.get!(Store, session.store_id),
      session: archived_session
    }
  end

  def restorable_session_fixture(user_id \\ nil, attrs \\ %{}) do
    archived_session_fixture(user_id, attrs, default_restorable_archive_time())
  end

  def expired_session_fixture(user_id \\ nil, attrs \\ %{}) do
    archived_session_fixture(user_id, attrs, DateTime.add(now(), -120, :day))
  end

  defp default_restorable_archive_time, do: DateTime.add(now(), -1, :day)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
