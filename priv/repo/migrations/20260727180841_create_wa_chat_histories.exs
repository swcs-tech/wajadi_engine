defmodule WajadiEngine.Repo.Migrations.CreateWaChatHistories do
  use Ecto.Migration

  def change do
    create table(:wa_chat_histories) do
      add :session_id, :text, null: false
      add :from, :text, null: false
      add :to, :text, null: false
      add :from_me, :boolean, null: false, default: false
      add :body, :text, null: false
      add :type, :text, null: false, default: "text"
      add :status, :text, null: false
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:wa_chat_histories, [:session_id], name: :wa_chat_histories_session_id_index)

    create index(:wa_chat_histories, [:session_id, :from, "inserted_at DESC"],
             name: :wa_chat_histories_session_from_inserted_at_index
           )

    create index(:wa_chat_histories, [:session_id, :to, "inserted_at DESC"],
             name: :wa_chat_histories_session_to_inserted_at_index
           )

    create index(:wa_chat_histories, [:session_id, :status],
             name: :wa_chat_histories_session_status_index
           )

    create index(:wa_chat_histories, [:session_id, :type],
             name: :wa_chat_histories_session_type_index
           )
  end
end
