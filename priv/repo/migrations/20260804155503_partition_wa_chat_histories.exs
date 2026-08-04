defmodule WajadiEngine.Repo.Migrations.PartitionWaChatHistories do
  use Ecto.Migration

  @enable_env "WAJADI_ENABLE_PG_PARTMAN_MIGRATION"

  def up do
    if enabled?() do
      rebuild_partitioned_chat_history_table()
      configure_pg_partman!()
    end
  end

  def down do
    if enabled?() do
      execute("DROP TABLE IF EXISTS wa_chat_histories CASCADE")
      create_unpartitioned_chat_history_table()
      create_chat_history_indexes()
    end
  end

  defp rebuild_partitioned_chat_history_table do
    execute("DROP TABLE IF EXISTS wa_chat_histories CASCADE")
    create_partitioned_chat_history_table()
    create_chat_history_indexes()
  end

  defp create_partitioned_chat_history_table do
    execute("""
    CREATE TABLE wa_chat_histories (
      id bigserial NOT NULL,
      store_id bigint NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
      session_id text NOT NULL,
      "from" text NOT NULL,
      "to" text NOT NULL,
      from_me boolean NOT NULL DEFAULT false,
      body text NOT NULL,
      type text NOT NULL DEFAULT 'text',
      status text NOT NULL,
      error text,
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL,
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """)
  end

  defp create_unpartitioned_chat_history_table do
    execute("""
    CREATE TABLE wa_chat_histories (
      id bigserial PRIMARY KEY,
      store_id bigint NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
      session_id text NOT NULL,
      "from" text NOT NULL,
      "to" text NOT NULL,
      from_me boolean NOT NULL DEFAULT false,
      body text NOT NULL,
      type text NOT NULL DEFAULT 'text',
      status text NOT NULL,
      error text,
      inserted_at timestamp(6) with time zone NOT NULL,
      updated_at timestamp(6) with time zone NOT NULL
    )
    """)
  end

  defp create_chat_history_indexes do
    execute("""
    CREATE INDEX wa_chat_histories_store_inserted_at_index
      ON wa_chat_histories (store_id, inserted_at DESC)
    """)

    execute("CREATE INDEX wa_chat_histories_session_id_index ON wa_chat_histories (session_id)")

    execute("""
    CREATE INDEX wa_chat_histories_session_inserted_at_index
      ON wa_chat_histories (session_id, inserted_at DESC)
    """)

    execute("""
    CREATE INDEX wa_chat_histories_session_from_inserted_at_index
      ON wa_chat_histories (session_id, "from", inserted_at DESC)
    """)

    execute("""
    CREATE INDEX wa_chat_histories_session_to_inserted_at_index
      ON wa_chat_histories (session_id, "to", inserted_at DESC)
    """)

    execute("""
    CREATE INDEX wa_chat_histories_session_status_index
      ON wa_chat_histories (session_id, status)
    """)

    execute("""
    CREATE INDEX wa_chat_histories_session_type_index
      ON wa_chat_histories (session_id, type)
    """)
  end

  defp configure_pg_partman! do
    execute("""
    SELECT partman.create_parent(
      p_parent_table := 'public.wa_chat_histories',
      p_control := 'inserted_at',
      p_type := 'native',
      p_interval := 'daily',
      p_premake := 7,
      p_start_partition := (date_trunc('day', now() AT TIME ZONE 'UTC') - interval '1 day')::date::text
    )
    """)

    execute("""
    UPDATE partman.part_config
    SET infinite_time_partitions = true,
        retention = '90 days',
        retention_keep_table = false
    WHERE parent_table = 'public.wa_chat_histories'
    """)
  end

  defp enabled?, do: System.get_env(@enable_env) == "true"
end
