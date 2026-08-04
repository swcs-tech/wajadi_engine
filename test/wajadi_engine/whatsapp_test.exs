defmodule WajadiEngine.WhatsAppTest do
  use WajadiEngine.DataCase

  alias WajadiEngine.Repo
  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.Session

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

      assert {:error, changeset} =
               %Session{}
               |> Session.create_changeset(%{
                 account_id: first.account_id,
                 store_id: first.store_id,
                 user_id: first.user_id,
                 session_id: "session-2",
                 status: "disconnected",
                 is_active: false
               })
               |> Repo.insert()

      assert %{store_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "archived sessions do not block another session for the same store" do
      assert {:ok, first} = WhatsApp.create_session("user-1", %{session_id: "session-1"})
      archived_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      purge_at = DateTime.add(archived_at, 90, :day)

      assert {:ok, _archived} =
               Session.update_changeset(first, %{archived_at: archived_at, purge_at: purge_at})
               |> Repo.update()

      assert {:ok, replacement} =
               %Session{}
               |> Session.create_changeset(%{
                 account_id: first.account_id,
                 store_id: first.store_id,
                 user_id: first.user_id,
                 session_id: "session-2",
                 status: "disconnected",
                 is_active: false
               })
               |> Repo.insert()

      assert replacement.store_id == first.store_id
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
end
