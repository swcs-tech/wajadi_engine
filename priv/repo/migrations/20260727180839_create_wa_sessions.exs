defmodule WajadiEngine.Repo.Migrations.CreateWaSessions do
  use Ecto.Migration

  def change do
    create table(:wa_sessions) do
      add :user_id, :text, null: false
      add :session_id, :text, null: false
      add :phone_number, :text
      add :status, :text, null: false, default: "disconnected"
      add :qr, :text
      add :is_active, :boolean, null: false, default: false
      add :last_connected_at, :utc_datetime_usec
      add :last_disconnected_at, :utc_datetime_usec
      add :last_qr_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wa_sessions, [:session_id], name: :wa_sessions_session_id_index)
    create index(:wa_sessions, [:user_id], name: :wa_sessions_user_id_index)
    create index(:wa_sessions, [:is_active, :status], name: :wa_sessions_active_status_index)

    create constraint(:wa_sessions, :wa_sessions_status_check,
             check: "status IN ('connecting', 'qr', 'connected', 'disconnected', 'paused')"
           )
  end
end
