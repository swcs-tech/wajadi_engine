# Account, Store, Session, and Catalog Lifecycle

## Ownership Model

An account is identified by normalized email. One account can own many stores and many WhatsApp sessions.

Every non-archived WhatsApp session belongs to exactly one store. A store can have at most one non-archived session, enforced by a partial database unique index.

Store personality and products belong to stores, not sessions. Moving a session changes only future store context; previous chat-history rows keep their stored `store_id` snapshot.

## Session Lifecycle

Session rows represent paired WhatsApp number connections.

Operational statuses are separate from archive state:

- `connecting`
- `qr`
- `connected`
- `disconnected`
- `paused`

Archiving a session stops runtime, clears auth state immediately, marks the session archived, and sets `purge_at` to 90 days after `archived_at`.

Restoring a session is allowed only before `purge_at`. Restore never restores auth state and always requires fresh QR pairing.

Permanent purge is handled by `WajadiEngine.WhatsApp.SessionCleanup` through the externally runnable Mix task or optional supervised scheduler.

## Store Lifecycle

Stores can be active, unassigned, or archived.

Archiving a store is rejected while it has a non-archived session. Move or archive the session first, then archive the store.

Products are archived with `is_active=false`; normal catalog reads and AI product tools return active products only.

## Retention Clocks

There are two independent retention clocks:

- Chat history retention: 90 days from `wa_chat_histories.inserted_at`, managed by `pg_partman` only.
- Session archive retention: 90 days from `wa_sessions.archived_at`, stored as `wa_sessions.purge_at`, managed by session cleanup.

`wa_auth_states` is not governed by chat retention. Auth state is cleared on logout and archive.

## AI Prompt Policy

Base system prompt, mandatory reply policy, and temperature are code-owned. Store personality is dynamic data loaded by trusted `account_id` and `store_id` context and cannot remove mandatory policy.

Product catalog tools are read-only and store-scoped.

## Management API Authorization

Management routes use authenticated account scope and must not trust route IDs alone. Current development API uses `x-account-email` as the trusted principal header and requires it to match route `account_id`.

Cross-account reads and writes return not found or a stable authorization failure envelope.

## Development Rollout

This project currently has no production database. Development rollout is reset-based:

1. Run migrations on a clean development database.
2. Seed demo data only when explicitly requested with `WAJADI_SEED_DEMO_DATA=true`.
3. Manually enable and verify `pg_partman` before running opt-in partition migrations.
4. Keep compatibility WhatsApp routes until callers move to account/store management APIs.

No backfill or production copy/swap path is included in this slice.
