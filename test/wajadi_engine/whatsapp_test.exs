defmodule WajadiEngine.WhatsAppTest do
  use WajadiEngine.DataCase

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.AuthState

  describe "sessions" do
    test "creates a session with provided session_id" do
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: "session-1"})

      assert session.user_id == "user-1"
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

      assert [restore_session] = WhatsApp.list_active_sessions_for_restore()
      assert restore_session.session_id == connected.session_id
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
  end

  describe "chat histories" do
    test "incoming row stores from_me false and received status" do
      assert {:ok, chat_history} =
               WhatsApp.create_incoming_chat_history(%{
                 session_id: "session-1",
                 from: "user@s.whatsapp.net",
                 to: "bot@s.whatsapp.net",
                 body: "hello"
               })

      assert chat_history.from_me == false
      assert chat_history.status == "received"
      assert chat_history.type == "text"
    end

    test "outgoing row stores from_me true and sent or failed status" do
      base_attrs = %{
        session_id: "session-1",
        from: "bot@s.whatsapp.net",
        to: "user@s.whatsapp.net",
        body: "hello"
      }

      assert {:ok, sent_history} = WhatsApp.create_outgoing_chat_history(base_attrs)
      assert sent_history.from_me == true
      assert sent_history.status == "sent"

      assert {:ok, failed_history} =
               base_attrs
               |> Map.merge(%{status: "failed", error: "send failed"})
               |> WhatsApp.create_outgoing_chat_history()

      assert failed_history.from_me == true
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
end
