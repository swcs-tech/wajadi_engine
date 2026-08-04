defmodule WajadiEngine.Repo.Migrations.CreateWaSessions do
  use Ecto.Migration

  def change do
    create table(:wa_sessions) do
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :store_id, references(:stores, on_delete: :restrict), null: false
      add :user_id, :text, null: false
      add :session_id, :text, null: false
      add :phone_number, :text
      add :status, :text, null: false, default: "disconnected"
      add :qr, :text
      add :is_active, :boolean, null: false, default: false
      add :last_connected_at, :utc_datetime_usec
      add :last_disconnected_at, :utc_datetime_usec
      add :last_qr_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :purge_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wa_sessions, [:session_id], name: :wa_sessions_session_id_index)
    create unique_index(:wa_sessions, [:store_id],
             name: :wa_sessions_one_non_archived_session_per_store_index,
             where: "archived_at IS NULL"
           )
    create index(:wa_sessions, [:account_id], name: :wa_sessions_account_id_index)
    create index(:wa_sessions, [:account_id, :session_id],
             name: :wa_sessions_account_session_id_index
           )
    create index(:wa_sessions, [:account_id, :store_id],
             name: :wa_sessions_account_store_id_index
           )
    create index(:wa_sessions, [:user_id], name: :wa_sessions_user_id_index)
    create index(:wa_sessions, [:is_active, :status], name: :wa_sessions_active_status_index)
    create index(:wa_sessions, [:purge_at],
             name: :wa_sessions_purge_at_index,
             where: "purge_at IS NOT NULL"
           )

    create constraint(:wa_sessions, :wa_sessions_status_check,
             check: "status IN ('connecting', 'qr', 'connected', 'disconnected', 'paused')"
           )
    create constraint(:wa_sessions, :wa_sessions_archive_window_check,
             check:
               "(archived_at IS NULL AND purge_at IS NULL) OR " <>
                 "(archived_at IS NOT NULL AND purge_at IS NOT NULL AND purge_at > archived_at)"
           )
  end
end
