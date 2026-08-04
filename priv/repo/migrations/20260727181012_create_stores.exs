defmodule WajadiEngine.Repo.Migrations.CreateStores do
  use Ecto.Migration

  def change do
    create table(:stores) do
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :archived_at, :utc_datetime_usec
      add :purge_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stores, [:account_id], name: :stores_account_id_index)
    create index(:stores, [:account_id, :status], name: :stores_account_status_index)

    create index(:stores, [:purge_at],
             name: :stores_purge_at_index,
             where: "purge_at IS NOT NULL"
           )

    create constraint(:stores, :stores_status_check,
             check: "status IN ('active', 'unassigned', 'archived')"
           )

    create constraint(:stores, :stores_archive_window_check,
             check:
               "(archived_at IS NULL AND purge_at IS NULL) OR " <>
                 "(archived_at IS NOT NULL AND purge_at IS NOT NULL AND purge_at > archived_at)"
           )
  end
end
