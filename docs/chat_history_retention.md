# Chat History Retention

Chat history retention is controlled by message age, not by WhatsApp session archive age.

## pg_partman Setup

`wa_chat_histories` uses `inserted_at` as the UTC partition key. `pg_partman` manages only chat-history partitions and their 90-day retention policy. Native range partitions use `p_type = 'range'` and daily partitions use PostgreSQL interval syntax `1 day`, required by pg_partman 5.x. Migration session timezone is explicitly set to UTC so partition boundaries do not depend on database timezone.

Partition migrations are opt-in because local and test databases may not have `pg_partman` installed. To run them manually after provisioning the extension package, set:

```bash
WAJADI_ENABLE_PG_PARTMAN_MIGRATION=true
```

Then run migrations in the target environment.

If the opt-in flag was not set and the migration versions were already recorded as `up`, rollback the two Phase 6 migrations and rerun them with `WAJADI_ENABLE_PG_PARTMAN_MIGRATION=true`.

## Partition Shape

The partitioned table keeps the same application columns and uses PostgreSQL native range partitioning:

```sql
PARTITION BY RANGE (inserted_at)
```

PostgreSQL requires primary or unique constraints on partitioned tables to include the partition key. The migration therefore uses:

```sql
PRIMARY KEY (id, inserted_at)
```

Application code still treats `id` as the schema primary key for ordinary inserts and reads.

## Development Data

This project is still in development and has no production data. The partition migration drops and recreates `wa_chat_histories` when `WAJADI_ENABLE_PG_PARTMAN_MIGRATION=true`; use the normal development `ecto.reset` workflow when enabling pg_partman locally.

## Retention

`pg_partman` is configured with:

```sql
retention = '90 days'
retention_keep_table = false
retention_keep_index = false
```

This makes partitions older than 90 days eligible for removal during `pg_partman` maintenance. It does not delete auth state rows and does not purge archived sessions.

## Maintenance

Run one maintenance mechanism only:

- `pg_partman_bgw` configured at database/server level.
- Managed database scheduler such as `pg_cron`.
- External scheduler that executes `SELECT partman.run_maintenance(p_parent_table := 'public.wa_chat_histories')`.

For manual maintenance without `pg_partman_bgw`, use a UTC session and do not wrap the procedure call in `BEGIN`/`COMMIT`; the procedure commits between partition sets:

```sql
SET TIME ZONE 'UTC';
CALL partman.run_maintenance_proc();
```

The migration creates UTC-midnight boundaries. PostgreSQL may display them as local `+07` values when the session timezone is `Asia/Bangkok`; compare boundary instants with `AT TIME ZONE 'UTC'` when verifying.

Monitor maintenance lag, missing future partitions, and failed maintenance runs through database logs or scheduler alerts.

## Session Archive Cleanup

Archived WhatsApp sessions use a separate retention clock based on `wa_sessions.purge_at`.

External one-shot cleanup remains available:

```bash
mix wajadi.sessions.purge --batch-size 100
```

An optional supervised scheduler can run the same cleanup daily. Configure it with:

```bash
WAJADI_SESSION_CLEANUP_ENABLED=true
WAJADI_SESSION_CLEANUP_INTERVAL_MS=86400000
WAJADI_SESSION_CLEANUP_BATCH_SIZE=100
WAJADI_SESSION_CLEANUP_RUN_ON_START=false
```

The scheduler emits bounded logs and uses the existing `SessionCleanup.purge_once/1` telemetry span. It never creates one process per archived row.
