defmodule WajadiEngine.Stores do
  @moduledoc """
  Account-scoped boundary for stores, personalities, and products.
  """

  import Ecto.Query

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores.Personality
  alias WajadiEngine.Stores.Product
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp.Session

  @archive_retention_days 90
  @default_personality """
  Kamu adalah admin toko Wajadi.
  Balas dalam Bahasa Indonesia dengan gaya ramah, singkat, natural, dan membantu.
  Jangan mengarang produk, harga, stok, promo, ongkir, atau estimasi.
  """

  @type store_result ::
          {:ok, Store.t()}
          | {:error, Ecto.Changeset.t() | :not_found | :store_in_use | :purge_deadline_passed}
  @type product_result :: {:ok, Product.t()} | {:error, Ecto.Changeset.t() | :not_found}

  @spec default_personality() :: String.t()
  def default_personality, do: String.trim(@default_personality)

  @spec list_stores(Account.t()) :: [Store.t()]
  def list_stores(%Account{id: account_id}) do
    Store
    |> where([store], store.account_id == ^account_id)
    |> where([store], is_nil(store.archived_at))
    |> order_by([store], asc: store.name, asc: store.id)
    |> Repo.all()
  end

  @spec fetch_store(Account.t(), integer()) :: {:ok, Store.t()} | {:error, :not_found}
  def fetch_store(%Account{id: account_id}, store_id) when is_integer(store_id) do
    case active_store_query(account_id, store_id) |> Repo.one() do
      %Store{} = store -> {:ok, store}
      nil -> {:error, :not_found}
    end
  end

  @spec fetch_store_by_scope(integer(), integer()) :: {:ok, Store.t()} | {:error, :not_found}
  def fetch_store_by_scope(account_id, store_id)
      when is_integer(account_id) and is_integer(store_id) do
    case active_store_query(account_id, store_id) |> Repo.one() do
      %Store{} = store -> {:ok, store}
      nil -> {:error, :not_found}
    end
  end

  @spec create_store(Account.t(), map()) :: {:ok, Store.t()} | {:error, Ecto.Changeset.t()}
  def create_store(%Account{} = account, attrs) when is_map(attrs) do
    %Store{}
    |> Store.create_changeset(account, attrs)
    |> Repo.insert()
  end

  @spec update_store(Account.t(), integer(), map()) :: store_result()
  def update_store(%Account{} = account, store_id, attrs)
      when is_integer(store_id) and is_map(attrs) do
    with {:ok, store} <- fetch_store(account, store_id) do
      attrs =
        Map.drop(attrs, [:status, "status", :archived_at, "archived_at", :purge_at, "purge_at"])

      store
      |> Store.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @spec archive_store(Account.t(), integer(), DateTime.t()) :: store_result()
  def archive_store(%Account{id: account_id}, store_id, archived_at \\ now())
      when is_integer(store_id) do
    Repo.transaction(fn ->
      with {:ok, store} <- lock_store(account_id, store_id, false),
           false <- non_archived_session_exists?(store.id) do
        purge_at = DateTime.add(archived_at, @archive_retention_days, :day)

        store
        |> Store.update_changeset(%{
          status: "archived",
          archived_at: archived_at,
          purge_at: purge_at
        })
        |> Repo.update()
        |> unwrap_transaction_result()
      else
        true -> Repo.rollback(:store_in_use)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> flatten_transaction()
  end

  @spec restore_store(Account.t(), integer(), DateTime.t()) :: store_result()
  def restore_store(%Account{id: account_id}, store_id, current_time \\ now())
      when is_integer(store_id) do
    Repo.transaction(fn ->
      with {:ok, store} <- lock_store(account_id, store_id, true),
           :ok <- ensure_before_purge(store, current_time) do
        store
        |> Store.update_changeset(%{
          status: restored_store_status(store.id),
          archived_at: nil,
          purge_at: nil
        })
        |> Repo.update()
        |> unwrap_transaction_result()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> flatten_transaction()
  end

  @spec get_effective_personality(Account.t(), integer()) ::
          {:ok, String.t()} | {:error, :not_found}
  def get_effective_personality(%Account{} = account, store_id) when is_integer(store_id) do
    with {:ok, store} <- fetch_store(account, store_id) do
      prompt =
        case Repo.get_by(Personality, store_id: store.id) do
          %Personality{prompt: prompt} -> prompt
          nil -> default_personality()
        end

      {:ok, prompt}
    end
  end

  @spec get_effective_personality(integer(), integer()) ::
          {:ok, String.t()} | {:error, :not_found}
  def get_effective_personality(account_id, store_id)
      when is_integer(account_id) and is_integer(store_id) do
    with {:ok, store} <- fetch_store_by_scope(account_id, store_id) do
      prompt =
        case Repo.get_by(Personality, store_id: store.id) do
          %Personality{prompt: prompt} -> prompt
          nil -> default_personality()
        end

      {:ok, prompt}
    end
  end

  @spec upsert_personality(Account.t(), integer(), map()) ::
          {:ok, Personality.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def upsert_personality(%Account{} = account, store_id, attrs)
      when is_integer(store_id) and is_map(attrs) do
    with {:ok, store} <- fetch_store(account, store_id) do
      %Personality{}
      |> Personality.changeset(store, attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:prompt, :updated_at]},
        conflict_target: :store_id,
        returning: true
      )
    end
  end

  @spec list_products(Account.t(), integer()) :: {:ok, [Product.t()]} | {:error, :not_found}
  def list_products(%Account{id: account_id}, store_id) when is_integer(store_id) do
    list_products(account_id, store_id)
  end

  @spec list_products(integer(), integer()) :: {:ok, [Product.t()]} | {:error, :not_found}
  def list_products(account_id, store_id) when is_integer(account_id) and is_integer(store_id) do
    with {:ok, store} <- fetch_store_by_scope(account_id, store_id) do
      products =
        Product
        |> where([product], product.store_id == ^store.id and product.is_active)
        |> order_by([product], asc: product.sort_order, asc: product.name, asc: product.id)
        |> Repo.all()

      {:ok, products}
    end
  end

  @spec fetch_product(Account.t(), integer(), integer()) ::
          {:ok, Product.t()} | {:error, :not_found}
  def fetch_product(%Account{id: account_id}, store_id, product_id)
      when is_integer(store_id) and is_integer(product_id) do
    query =
      from product in Product,
        join: store in Store,
        on: store.id == product.store_id,
        where:
          product.id == ^product_id and product.store_id == ^store_id and
            store.account_id == ^account_id and is_nil(store.archived_at) and product.is_active

    case Repo.one(query) do
      %Product{} = product -> {:ok, product}
      nil -> {:error, :not_found}
    end
  end

  @spec create_product(Account.t(), integer(), map()) :: product_result()
  def create_product(%Account{} = account, store_id, attrs)
      when is_integer(store_id) and is_map(attrs) do
    with {:ok, store} <- fetch_store(account, store_id) do
      %Product{}
      |> Product.create_changeset(store, attrs)
      |> Repo.insert()
    end
  end

  @spec update_product(Account.t(), integer(), integer(), map()) :: product_result()
  def update_product(%Account{} = account, store_id, product_id, attrs)
      when is_integer(store_id) and is_integer(product_id) and is_map(attrs) do
    with {:ok, product} <- fetch_product(account, store_id, product_id) do
      product
      |> Product.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @spec archive_product(Account.t(), integer(), integer()) :: product_result()
  def archive_product(%Account{} = account, store_id, product_id)
      when is_integer(store_id) and is_integer(product_id) do
    with {:ok, product} <- fetch_product(account, store_id, product_id) do
      product
      |> Product.archive_changeset()
      |> Repo.update()
    end
  end

  defp active_store_query(account_id, store_id) do
    from store in Store,
      where:
        store.id == ^store_id and store.account_id == ^account_id and is_nil(store.archived_at)
  end

  defp lock_store(account_id, store_id, archived?) do
    archive_filter =
      if archived?,
        do: dynamic([store], not is_nil(store.archived_at)),
        else: dynamic([store], is_nil(store.archived_at))

    query =
      Store
      |> where([store], store.id == ^store_id and store.account_id == ^account_id)
      |> where(^archive_filter)
      |> lock("FOR UPDATE")

    case Repo.one(query) do
      %Store{} = store -> {:ok, store}
      nil -> {:error, :not_found}
    end
  end

  defp non_archived_session_exists?(store_id) do
    Session
    |> where([session], session.store_id == ^store_id and is_nil(session.archived_at))
    |> Repo.exists?()
  end

  defp restored_store_status(store_id) do
    if non_archived_session_exists?(store_id), do: "active", else: "unassigned"
  end

  defp ensure_before_purge(%Store{purge_at: purge_at}, current_time) do
    if DateTime.compare(purge_at, current_time) == :gt,
      do: :ok,
      else: {:error, :purge_deadline_passed}
  end

  defp unwrap_transaction_result({:ok, value}), do: value
  defp unwrap_transaction_result({:error, reason}), do: Repo.rollback(reason)

  defp flatten_transaction({:ok, value}), do: {:ok, value}
  defp flatten_transaction({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
