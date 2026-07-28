defmodule WajadiEngine.WhatsApp.SessionServerTest do
  use WajadiEngine.DataCase

  alias WajadiEngine.WhatsApp
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

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      ref = Process.monitor(pid)
      assert :ok = SessionServer.delete(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert is_nil(WhatsApp.get_session(session.session_id))
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
end
