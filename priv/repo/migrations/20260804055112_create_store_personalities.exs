defmodule WajadiEngine.Repo.Migrations.CreateStorePersonalities do
  use Ecto.Migration

  def change do
    create table(:store_personalities) do
      add :store_id, references(:stores, on_delete: :delete_all), null: false
      add :prompt, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:store_personalities, [:store_id],
             name: :store_personalities_store_id_index
           )

    create constraint(:store_personalities, :store_personalities_prompt_not_blank,
             check: "btrim(prompt) <> ''"
           )
  end
end
