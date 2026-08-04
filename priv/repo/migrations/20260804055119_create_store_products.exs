defmodule WajadiEngine.Repo.Migrations.CreateStoreProducts do
  use Ecto.Migration

  def change do
    create table(:store_products) do
      add :store_id, references(:stores, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :sku, :text
      add :description, :text
      add :price, :decimal, precision: 15, scale: 2, null: false
      add :currency, :text, null: false, default: "IDR"
      add :stock_quantity, :integer
      add :availability, :text, null: false, default: "unknown"
      add :image_url, :text
      add :is_active, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:store_products, [:store_id, :sku],
             name: :store_products_store_id_sku_index,
             where: "sku IS NOT NULL"
           )

    create index(:store_products, [:store_id, :is_active, :sort_order, :id],
             name: :store_products_store_active_sort_index
           )

    create constraint(:store_products, :store_products_name_not_blank, check: "btrim(name) <> ''")

    create constraint(:store_products, :store_products_price_non_negative, check: "price >= 0")

    create constraint(:store_products, :store_products_stock_non_negative,
             check: "stock_quantity IS NULL OR stock_quantity >= 0"
           )

    create constraint(:store_products, :store_products_sort_order_non_negative,
             check: "sort_order >= 0"
           )

    create constraint(:store_products, :store_products_availability_check,
             check: "availability IN ('unknown', 'available', 'out_of_stock', 'preorder')"
           )
  end
end
