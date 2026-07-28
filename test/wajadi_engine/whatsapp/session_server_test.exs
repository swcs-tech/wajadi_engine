defmodule WajadiEngine.WhatsApp.SessionServerTest do
  use WajadiEngine.DataCase

  import Ecto.Query

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.SessionRestorer
  alias WajadiEngine.WhatsApp.SessionServer
  alias WajadiEngine.WhatsApp.SessionSupervisor

  describe "SessionSupervisor" do
    test "starts one runtime process per session_id" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert is_pid(pid)
      assert SessionSupervisor.whereis(session.session_id) == pid

      assert {:ok, ^pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )
    end
  end

  describe "SessionServer API" do
    test "QR connection update stores raw QR and marks session inactive" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      send(pid, {:amarula, :connection_update, %{qr: "raw-qr-code"}})
      :sys.get_state(pid)

      assert {:ok, updated} = WhatsApp.fetch_session(session.session_id)
      assert updated.status == "qr"
      assert updated.qr == "raw-qr-code"
      assert updated.is_active == false
      assert %DateTime{} = updated.last_qr_at
    end

    test "open connection update marks connected, clears QR, and stores phone number" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, session} = WhatsApp.mark_session_qr(session, "old-qr")

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      send(
        pid,
        {:amarula, :connection_update, %{connection: :open, me: %{id: "628123:1@s.whatsapp.net"}}}
      )

      :sys.get_state(pid)

      assert {:ok, updated} = WhatsApp.fetch_session(session.session_id)
      assert updated.status == "connected"
      assert updated.qr == nil
      assert updated.is_active == true
      assert updated.phone_number == "628123"
      assert %DateTime{} = updated.last_connected_at
    end

    test "pause, resume, and disconnect update session status" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, paused} = SessionServer.pause(pid)
      assert paused.status == "paused"
      assert paused.is_active == true

      assert {:error, :not_connected} = SessionServer.resume(pid)

      assert {:ok, disconnected} = SessionServer.disconnect(pid)
      assert disconnected.status == "disconnected"
      assert disconnected.is_active == false
    end

    test "disconnect preserves auth rows" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, _auth_state} =
               WhatsApp.create_auth_state(%{
                 session_id: session.session_id,
                 type: "creds",
                 key: "creds",
                 value: %{"id" => "1"}
               })

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: %{offline: true, connection_state: :connected}
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, disconnected} = SessionServer.disconnect(pid)
      assert disconnected.status == "disconnected"
      assert count_auth_states(session.session_id) == 1
    end

    test "connect can start an offline Amarula connection" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: %{offline: true, connection_state: :connected}
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, conn_pid} = SessionServer.connect(pid)
      assert is_pid(conn_pid)
      assert {:ok, msg_id} = SessionServer.send_reply(pid, "628123@s.whatsapp.net", "hi")
      assert is_binary(msg_id)
    end

    test "delete removes session and stops runtime process" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, _auth_state} =
               WhatsApp.create_auth_state(%{
                 session_id: session.session_id,
                 type: "creds",
                 key: "creds",
                 value: %{"id" => "1"}
               })

      assert {:ok, _chat_history} =
               WhatsApp.create_incoming_chat_history(%{
                 session_id: session.session_id,
                 from: "user@s.whatsapp.net",
                 to: "bot@s.whatsapp.net",
                 body: "hello"
               })

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      ref = Process.monitor(pid)
      assert :ok = SessionServer.delete(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert is_nil(WhatsApp.get_session(session.session_id))
      assert count_auth_states(session.session_id) == 0
      assert WhatsApp.count_chat_histories(session.session_id) == 1
    end
  end

  describe "SessionRestorer" do
    test "starts active connected sessions only" do
      active_session_id = unique_session_id()
      inactive_session_id = unique_session_id()

      assert {:ok, active} = WhatsApp.create_session("user-1", %{session_id: active_session_id})

      assert {:ok, inactive} =
               WhatsApp.create_session("user-1", %{session_id: inactive_session_id})

      assert {:ok, active} = WhatsApp.mark_session_connected(active)
      assert {:ok, _inactive} = WhatsApp.mark_session_disconnected(inactive)

      on_exit(fn -> SessionSupervisor.stop_session(active.session_id) end)

      assert {:ok, %{started: 1, failed: 0}} =
               SessionRestorer.restore_active_sessions(connect: false)

      assert is_pid(SessionSupervisor.whereis(active.session_id))
      assert is_nil(SessionSupervisor.whereis(inactive.session_id))
    end
  end

  defp unique_session_id do
    "session-#{System.unique_integer([:positive])}"
  end

  defp count_auth_states(session_id) do
    AuthState
    |> where([auth_state], auth_state.session_id == ^session_id)
    |> Repo.aggregate(:count)
  end
end
