defmodule WajadiEngine.Repo.Migrations.CreateWaAuthStates do
  use Ecto.Migration

  def change do
    create table(:wa_auth_states) do
      add :session_id, :text, null: false
      add :type, :text, null: false
      add :key, :text, null: false
      add :value, :map, null: false
      add :encoding, :text, null: false, default: "json"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wa_auth_states, [:session_id, :type, :key],
             name: :wa_auth_states_session_id_type_key_index
           )

    create index(:wa_auth_states, [:session_id, :type],
             name: :wa_auth_states_session_id_type_index
           )

    create constraint(:wa_auth_states, :wa_auth_states_encoding_check,
             check: "encoding IN ('json', 'erlang_term_base64')"
           )
  end
end
