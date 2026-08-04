defmodule WajadiEngine.WhatsAppTest do
  use WajadiEngine.DataCase

  alias WajadiEngine.Repo
  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.Session
  alias WajadiEngine.WhatsApp.SessionCleanup

  describe "accounts" do
    test "normalizes account email before unique checks" do
      assert {:ok, first} =
               WhatsApp.create_session(" Owner@Example.COM ", %{session_id: "session-1"})

      assert {:ok, second} =
               WhatsApp.create_session("owner@example.com", %{session_id: "session-2"})

      assert first.user_id == "owner@example.com"
      assert second.user_id == "owner@example.com"
      assert Repo.aggregate(Account, :count) == 1
    end

    test "database rejects duplicate normalized account email" do
      attrs = %{email: "Owner@Example.COM"}
      assert {:ok, _account} = %Account{} |> Account.create_changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Account{}
               |> Account.create_changeset(%{email: " owner@example.com "})
               |> Repo.insert()

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects blank account identity without inserting account rows" do
      assert {:error, changeset} = WhatsApp.create_session(" ", %{session_id: "session-1"})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
      assert Repo.aggregate(Account, :count) == 0
    end
  end

  describe "stores" do
    test "store requires an existing account" do
      changeset =
        Store.create_changeset(%Store{}, %Account{id: -1}, %{name: "Main Store", status: "active"})

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{account_id: ["does not exist"]} = errors_on(changeset)
    end

    test "store validates archive purge window" do
      assert {:ok, session} =
               WhatsApp.create_session("owner@example.com", %{session_id: "session-1"})

      store = Repo.get!(Store, session.store_id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      before_archive = DateTime.add(now, -1, :second)

      changeset = Store.update_changeset(store, %{archived_at: now, purge_at: before_archive})

      refute changeset.valid?
      assert %{purge_at: ["must be after archived_at"]} = errors_on(changeset)
    end
  end

  describe "sessions" do
    test "creates a session with provided session_id" do
      assert {:ok, session} = WhatsApp.create_session("User-1", %{session_id: "session-1"})

      assert session.user_id == "user-1"
      assert is_integer(session.account_id)
      assert is_integer(session.store_id)
      assert session.session_id == "session-1"
      assert session.status == "disconnected"
      assert session.is_active == false
    end

    test "creates a session with generated session_id" do
      assert {:ok, session} = WhatsApp.create_session("user-1")

      assert String.starts_with?(session.session_id, "user-1_")
    end

    test "lists sessions scoped by user_id" do
      assert {:ok, first} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, second} = WhatsApp.create_session("user-1", %{session_id: "session-2"})
      assert {:ok, _other} = WhatsApp.create_session("user-2", %{session_id: "session-3"})

      session_ids = WhatsApp.list_sessions("user-1") |> Enum.map(& &1.session_id)

      assert first.session_id in session_ids
      assert second.session_id in session_ids
      refute "session-3" in session_ids
    end

    test "returns not found for another user's session" do
      assert {:ok, _session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      assert {:error, :not_found} = WhatsApp.fetch_session_for_user("user-2", "session-1")
    end

    test "lists active connected sessions for restore" do
      assert {:ok, connected} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, disconnected} = WhatsApp.create_session("user-1", %{session_id: "session-2"})
      assert {:ok, connected} = WhatsApp.mark_session_connected(connected)
      assert {:ok, _disconnected} = WhatsApp.mark_session_disconnected(disconnected)
      assert {:ok, _auth_state} = create_creds(connected.session_id)

      assert [restore_session] = WhatsApp.list_active_sessions_for_restore()
      assert restore_session.session_id == connected.session_id
    end

    test "lists reconnecting sessions with credentials for restore" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, session} = WhatsApp.mark_session_connected(session)
      assert {:ok, session} = WhatsApp.mark_session_reconnecting(session)
      assert {:ok, _auth_state} = create_creds(session.session_id)

      assert [restore_session] = WhatsApp.list_active_sessions_for_restore()
      assert restore_session.session_id == session.session_id
    end

    test "restores paired sessions even if status was disconnected prior to restart" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, session} = WhatsApp.mark_session_disconnected(session)
      assert {:ok, _auth_state} = create_creds(session.session_id)

      assert [restore_session] = WhatsApp.list_active_sessions_for_restore()
      assert restore_session.session_id == session.session_id
    end

    test "skips active sessions without stored credentials for restore" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert WhatsApp.list_active_sessions_for_restore() == []
    end

    test "status transitions match allowed lifecycle values" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, session} = WhatsApp.mark_session_connecting(session)
      assert session.status == "connecting"
      assert session.is_active == false
      assert is_nil(session.qr)

      assert {:ok, session} = WhatsApp.mark_session_qr(session, "raw-qr")
      assert session.status == "qr"
      assert session.qr == "raw-qr"
      assert session.is_active == false
      assert %DateTime{} = session.last_qr_at

      assert {:ok, session} = WhatsApp.mark_session_connected(session, %{phone_number: "628123"})
      assert session.status == "connected"
      assert session.phone_number == "628123"
      assert session.is_active == true
      assert is_nil(session.qr)
      assert %DateTime{} = session.last_connected_at

      assert {:ok, session} = WhatsApp.mark_session_reconnecting(session)
      assert session.status == "connecting"
      assert session.is_active == true
      assert is_nil(session.qr)

      assert {:ok, session} = WhatsApp.pause_session(session)
      assert session.status == "paused"
      assert session.is_active == true

      assert {:ok, session} = WhatsApp.resume_session(session)
      assert session.status == "connected"
      assert session.is_active == true

      assert {:ok, session} = WhatsApp.mark_session_disconnected(session)
      assert session.status == "disconnected"
      assert session.is_active == false
      assert %DateTime{} = session.last_disconnected_at
    end

    test "rejects invalid status values" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      assert {:error, changeset} =
               session
               |> WajadiEngine.WhatsApp.Session.update_changeset(%{status: "invalid"})
               |> Repo.update()

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "database rejects two non-archived sessions for one store" do
      assert {:ok, first} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      account = Repo.get!(Account, first.account_id)
      store = Repo.get!(Store, first.store_id)

      assert {:error, changeset} =
               %Session{}
               |> Session.create_changeset(account, store, %{
                 session_id: "session-2",
                 status: "disconnected",
                 is_active: false
               })
               |> Repo.insert()

      assert %{store_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "archived sessions do not block another session for the same store" do
      assert {:ok, first} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")
      archived_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, _archived} = WhatsApp.archive_session(account, first.session_id, archived_at)

      assert {:ok, replacement} =
               WhatsApp.create_session("user-1", %{
                 session_id: "session-2",
                 store_id: first.store_id
               })

      assert replacement.store_id == first.store_id
    end

    test "creates a session using an owned unassigned store" do
      account =
        %Account{}
        |> Account.create_changeset(%{email: "owner@example.com"})
        |> Repo.insert!()

      assert {:ok, store} = Stores.create_store(account, %{name: "Existing Store"})

      assert {:ok, session} =
               WhatsApp.create_session(account.email, %{
                 session_id: "session-1",
                 store_id: store.id
               })

      assert session.account_id == account.id
      assert session.store_id == store.id
      assert Repo.get!(Store, store.id).status == "active"
    end

    test "rejects another account's store during session creation" do
      owner =
        %Account{} |> Account.create_changeset(%{email: "owner@example.com"}) |> Repo.insert!()

      assert {:ok, store} = Stores.create_store(owner, %{name: "Private Store"})

      assert {:error, :store_not_available} =
               WhatsApp.create_session("attacker@example.com", %{
                 session_id: "session-1",
                 store_id: store.id
               })
    end

    test "moves a session within an account while preserving old chat snapshots" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")
      assert {:ok, target_store} = Stores.create_store(account, %{name: "Target"})

      assert {:ok, old_history} = incoming_history(session.session_id, "before")

      old_context = %{
        account_id: session.account_id,
        store_id: session.store_id,
        session_id: session.session_id
      }

      assert {:ok, moved} = WhatsApp.move_session(account, session.session_id, target_store.id)
      assert moved.store_id == target_store.id
      assert {:ok, new_history} = incoming_history(session.session_id, "after")

      assert {:ok, in_flight_reply} =
               WhatsApp.create_outgoing_chat_history(old_context, %{
                 from: "bot@s.whatsapp.net",
                 to: "user@s.whatsapp.net",
                 body: "reply from in-flight turn"
               })

      assert old_history.store_id == session.store_id
      assert new_history.store_id == target_store.id
      assert in_flight_reply.store_id == session.store_id
      assert Repo.get!(Store, session.store_id).status == "unassigned"
      assert Repo.get!(Store, target_store.id).status == "active"
    end

    test "rejects movement across accounts and into an occupied store" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, occupied} = WhatsApp.create_session("user-1", %{session_id: "session-2"})
      assert {:ok, _other} = WhatsApp.create_session("user-2", %{session_id: "session-3"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")
      assert {:ok, other_account} = WhatsApp.fetch_account("user-2")

      assert {:error, :not_found} =
               WhatsApp.move_session(other_account, session.session_id, occupied.store_id)

      assert {:error, :store_occupied} =
               WhatsApp.move_session(account, session.session_id, occupied.store_id)
    end

    test "archives session, clears auth, and restores without auth before deadline" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")
      assert {:ok, _auth} = create_creds(session.session_id)
      archived_at = ~U[2026-01-01 00:00:00.000000Z]

      assert {:ok, archived} = WhatsApp.archive_session(account, session.session_id, archived_at)
      assert archived.status == "disconnected"
      assert archived.is_active == false
      assert archived.purge_at == ~U[2026-04-01 00:00:00.000000Z]
      assert Repo.aggregate(AuthState, :count) == 0

      assert {:error, :not_found} =
               WhatsApp.fetch_session_for_account(account, session.session_id)

      assert {:ok, ^archived} = WhatsApp.fetch_archived_session(account, session.session_id)

      assert {:ok, restored} =
               WhatsApp.restore_session(
                 account,
                 session.session_id,
                 ~U[2026-03-31 00:00:00.000000Z]
               )

      assert restored.status == "disconnected"
      assert restored.is_active == false
      assert is_nil(restored.archived_at)
      assert is_nil(restored.purge_at)
      assert Repo.aggregate(AuthState, :count) == 0
    end

    test "rejects restore after purge deadline and when store is occupied" do
      assert {:ok, expired} = WhatsApp.create_session("user-1", %{session_id: "expired"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")
      archived_at = ~U[2026-01-01 00:00:00.000000Z]
      assert {:ok, _archived} = WhatsApp.archive_session(account, expired.session_id, archived_at)

      assert {:error, :purge_deadline_passed} =
               WhatsApp.restore_session(
                 account,
                 expired.session_id,
                 ~U[2026-04-01 00:00:00.000000Z]
               )

      assert {:ok, _replacement} =
               WhatsApp.create_session("user-1", %{
                 session_id: "replacement",
                 store_id: expired.store_id
               })

      assert {:error, :store_occupied} =
               WhatsApp.restore_session(
                 account,
                 expired.session_id,
                 ~U[2026-03-01 00:00:00.000000Z]
               )
    end

    test "purges only expired archives and defensively clears auth" do
      assert {:ok, expired} = WhatsApp.create_session("user-1", %{session_id: "expired"})
      assert {:ok, retained} = WhatsApp.create_session("user-1", %{session_id: "retained"})
      assert {:ok, account} = WhatsApp.fetch_account("user-1")

      assert {:ok, _expired} =
               WhatsApp.archive_session(
                 account,
                 expired.session_id,
                 ~U[2026-01-01 00:00:00.000000Z]
               )

      assert {:ok, _retained} =
               WhatsApp.archive_session(
                 account,
                 retained.session_id,
                 ~U[2026-03-01 00:00:00.000000Z]
               )

      assert {:ok, _orphaned_auth} = create_creds(expired.session_id)

      assert %{selected: 1, purged: 1, skipped: 0, failed: 0} =
               SessionCleanup.purge_once(now: ~U[2026-04-01 00:00:00.000000Z])

      refute Repo.get(Session, expired.id)
      assert Repo.get(Session, retained.id)
      refute Repo.get_by(AuthState, session_id: expired.session_id)

      assert %{selected: 0, purged: 0, skipped: 0, failed: 0} =
               SessionCleanup.purge_once(now: ~U[2026-04-01 00:00:00.000000Z])
    end
  end

  describe "chat histories" do
    test "incoming row stores from_me false and received status" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      assert {:ok, chat_history} =
               WhatsApp.create_incoming_chat_history(%{
                 session_id: session.session_id,
                 from: "user@s.whatsapp.net",
                 to: "bot@s.whatsapp.net",
                 body: "hello"
               })

      assert chat_history.store_id == session.store_id
      assert chat_history.from_me == false
      assert chat_history.status == "received"
      assert chat_history.type == "text"
    end

    test "outgoing row stores from_me true and sent or failed status" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      base_attrs = %{
        session_id: session.session_id,
        from: "bot@s.whatsapp.net",
        to: "user@s.whatsapp.net",
        body: "hello"
      }

      assert {:ok, sent_history} = WhatsApp.create_outgoing_chat_history(base_attrs)
      assert sent_history.store_id == session.store_id
      assert sent_history.from_me == true
      assert sent_history.status == "sent"

      assert {:ok, failed_history} =
               base_attrs
               |> Map.merge(%{status: "failed", error: "send failed"})
               |> WhatsApp.create_outgoing_chat_history()

      assert failed_history.from_me == true
      assert failed_history.store_id == session.store_id
      assert failed_history.status == "failed"
      assert failed_history.error == "send failed"
    end

    test "deleting session preserves chat histories" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      assert {:ok, _chat_history} =
               WhatsApp.create_incoming_chat_history(%{
                 session_id: session.session_id,
                 from: "user@s.whatsapp.net",
                 to: "bot@s.whatsapp.net",
                 body: "hello"
               })

      assert {:ok, _deleted} = WhatsApp.delete_session(session)

      assert is_nil(WhatsApp.get_session(session.session_id))
      assert WhatsApp.count_chat_histories(session.session_id) == 1
    end
  end

  describe "auth states" do
    test "delete and clear helpers remove scoped auth rows" do
      assert {:ok, _creds} =
               WhatsApp.create_auth_state(%{
                 session_id: "session-1",
                 type: "creds",
                 key: "creds",
                 value: %{"noiseKey" => "value"}
               })

      assert {:ok, _session_key} =
               WhatsApp.create_auth_state(%{
                 session_id: "session-1",
                 type: "session",
                 key: "user-1",
                 value: %{"record" => "value"}
               })

      assert :ok = WhatsApp.delete_auth_state("session-1", "session", "user-1")
      refute Repo.get_by(AuthState, session_id: "session-1", type: "session", key: "user-1")

      assert WhatsApp.clear_auth_states("session-1") == 1
      refute Repo.get_by(AuthState, session_id: "session-1", type: "creds", key: "creds")
    end

    test "lists auth state metadata without exposing values" do
      assert {:ok, _creds} =
               WhatsApp.create_auth_state(%{
                 session_id: "session-1",
                 type: "creds",
                 key: "creds",
                 value: %{"secret" => "hidden"},
                 encoding: "json"
               })

      assert {:ok, _session_key} =
               WhatsApp.create_auth_state(%{
                 session_id: "session-1",
                 type: "session",
                 key: "device-1",
                 value: %{"data" => "hidden"},
                 encoding: "erlang_term_base64"
               })

      assert [creds_metadata, session_metadata] = WhatsApp.list_auth_state_metadata("session-1")

      assert creds_metadata == %{
               type: "creds",
               key: "creds",
               encoding: "json",
               updated_at: creds_metadata.updated_at
             }

      assert session_metadata == %{
               type: "session",
               key: "device-1",
               encoding: "erlang_term_base64",
               updated_at: session_metadata.updated_at
             }

      assert %DateTime{} = creds_metadata.updated_at
      assert %DateTime{} = session_metadata.updated_at
      refute Map.has_key?(creds_metadata, :value)
      refute Map.has_key?(session_metadata, :value)
    end
  end

  defp create_creds(session_id) do
    WhatsApp.create_auth_state(%{
      session_id: session_id,
      type: "creds",
      key: "creds",
      value: %{"id" => "1"}
    })
  end

  defp incoming_history(session_id, body) do
    WhatsApp.create_incoming_chat_history(%{
      session_id: session_id,
      from: "user@s.whatsapp.net",
      to: "bot@s.whatsapp.net",
      body: body
    })
  end
end
