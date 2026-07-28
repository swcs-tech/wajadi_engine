defmodule WajadiEngineWeb.WhatsAppControllerTest do
  use WajadiEngineWeb.ConnCase

  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.SessionSupervisor

  describe "GET /api/whatsapp/account/:user_id/list" do
    test "lists sessions scoped by user", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      assert {:ok, _other} = WhatsApp.create_session("user-2", %{session_id: unique_session_id()})

      response =
        conn
        |> get(~p"/api/whatsapp/account/user-1/list")
        |> json_response(200)

      assert response["success"] == true
      assert response["message"] == "List of sessions"
      assert [%{"session_id" => session_id}] = response["data"]["sessions"]
      assert session_id == session.session_id
    end
  end

  describe "POST /api/whatsapp/account/:user_id/create" do
    test "creates session with provided session_id", %{conn: conn} do
      session_id = unique_session_id()

      response =
        conn
        |> post(~p"/api/whatsapp/account/user-1/create", %{session_id: session_id})
        |> json_response(201)

      on_exit(fn -> SessionSupervisor.stop_session(session_id) end)

      assert response["success"] == true
      assert response["message"] == "Session created"

      assert response["data"] == %{
               "session_id" => session_id,
               "user_id" => "user-1",
               "status" => "connecting"
             }

      assert {:ok, session} = WhatsApp.fetch_session_for_user("user-1", session_id)
      assert session.status == "connecting"
      assert_runtime_started(session_id)
    end

    test "creates session with generated session_id", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/whatsapp/account/user-1/create", %{})
        |> json_response(201)

      session_id = response["data"]["session_id"]
      on_exit(fn -> SessionSupervisor.stop_session(session_id) end)
      assert_runtime_started(session_id)

      assert String.starts_with?(session_id, "user-1_")
      assert response["data"]["status"] == "connecting"
    end

    test "returns validation error for invalid session_id", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/whatsapp/account/user-1/create", %{session_id: ""})
        |> json_response(400)

      assert response["success"] == false
      assert response["message"] == "Validation failed"
      assert [%{"path" => ["session_id"]}] = response["error"]["errors"]
    end

    test "rejects connected existing session", %{conn: conn} do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      response =
        conn
        |> post(~p"/api/whatsapp/account/user-1/create", %{session_id: session_id})
        |> json_response(400)

      assert response["message"] == "Session already connected"
      assert response["error"]["session_id"] == session_id
      assert response["error"]["status"] == "connected"
    end
  end

  describe "QR routes" do
    test "shows QR status for owned session", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      assert {:ok, session} = WhatsApp.mark_session_qr(session, "raw-qr")

      response =
        conn
        |> get(~p"/api/whatsapp/account/user-1/qr/#{session.session_id}/view")
        |> json_response(200)

      assert response["message"] == "Session QR and status"

      assert response["data"] == %{
               "session_id" => session.session_id,
               "status" => "qr",
               "qr" => "raw-qr",
               "is_active" => false
             }
    end

    test "refreshes QR by restarting runtime", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      response =
        conn
        |> get(~p"/api/whatsapp/account/user-1/qr/#{session.session_id}/refresh")
        |> json_response(200)

      assert response["message"] == "QR refreshed"
      assert response["data"] == %{"session_id" => session.session_id, "status" => "connecting"}
      assert_runtime_started(session.session_id)
    end
  end

  describe "lifecycle routes" do
    test "connect starts runtime and marks connecting", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      response =
        conn
        |> patch(~p"/api/whatsapp/account/user-1/connect/#{session.session_id}")
        |> json_response(200)

      assert response["message"] == "Session connecting"
      assert response["data"] == %{"session_id" => session.session_id, "status" => "connecting"}
      assert_runtime_started(session.session_id)
    end

    test "disconnect marks disconnected", %{conn: conn} do
      session = create_runtime_session!()

      response =
        conn
        |> patch(~p"/api/whatsapp/account/#{session.user_id}/disconnect/#{session.session_id}")
        |> json_response(200)

      assert response["message"] == "Session disconnected"
      assert response["data"] == %{"session_id" => session.session_id, "status" => "disconnected"}
    end

    test "pause and resume require active runtime", %{conn: conn} do
      session = create_runtime_session!()

      pause_response =
        conn
        |> patch(~p"/api/whatsapp/account/#{session.user_id}/pause/#{session.session_id}")
        |> json_response(200)

      assert pause_response["message"] == "Session paused — bot auto-reply OFF"
      assert pause_response["data"] == %{"session_id" => session.session_id, "status" => "paused"}

      resume_response =
        build_conn()
        |> patch(~p"/api/whatsapp/account/#{session.user_id}/resume/#{session.session_id}")
        |> json_response(200)

      assert resume_response["message"] == "Session resumed — bot auto-reply ON"

      assert resume_response["data"] == %{
               "session_id" => session.session_id,
               "status" => "connected"
             }
    end

    test "pause returns bad request when runtime inactive", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      response =
        conn
        |> patch(~p"/api/whatsapp/account/user-1/pause/#{session.session_id}")
        |> json_response(400)

      assert response["message"] == "Session is not active — cannot pause"
    end

    test "logout clears auth state and disconnects", %{conn: conn} do
      session = create_runtime_session!()

      assert {:ok, _auth_state} =
               WhatsApp.create_auth_state(%{
                 session_id: session.session_id,
                 type: "creds",
                 key: "creds",
                 value: %{"id" => "1"}
               })

      response =
        conn
        |> delete(~p"/api/whatsapp/account/#{session.user_id}/logout/#{session.session_id}")
        |> json_response(200)

      assert response["message"] == "Session logged out"
      assert response["data"] == %{"session_id" => session.session_id, "status" => "disconnected"}
      assert WajadiEngine.Repo.aggregate(WajadiEngine.WhatsApp.AuthState, :count) == 0
    end

    test "delete removes session and preserves chat history", %{conn: conn} do
      session = create_runtime_session!()

      assert {:ok, _chat_history} =
               WhatsApp.create_incoming_chat_history(%{
                 session_id: session.session_id,
                 from: "user@s.whatsapp.net",
                 to: "bot@s.whatsapp.net",
                 body: "hello"
               })

      response =
        conn
        |> delete(~p"/api/whatsapp/account/#{session.user_id}/delete/#{session.session_id}")
        |> json_response(200)

      assert response["message"] == "Session deleted permanently"
      assert response["data"] == %{"session_id" => session.session_id}
      assert is_nil(WhatsApp.get_session(session.session_id))
      assert WhatsApp.count_chat_histories(session.session_id) == 1
    end
  end

  describe "ownership" do
    test "returns not found for another user's session", %{conn: conn} do
      assert {:ok, session} =
               WhatsApp.create_session("user-1", %{session_id: unique_session_id()})

      response =
        conn
        |> get(~p"/api/whatsapp/account/user-2/qr/#{session.session_id}/view")
        |> json_response(404)

      assert response["success"] == false
      assert response["message"] == "Session not found"
    end
  end

  defp create_runtime_session! do
    session_id = unique_session_id()
    assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

    assert {:ok, _pid} =
             SessionSupervisor.start_session(
               session.user_id,
               session.session_id,
               Application.fetch_env!(:wajadi_engine, :whatsapp_session_start_opts)
             )

    assert_runtime_started(session.session_id)
    on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)
    session
  end

  defp assert_runtime_started(session_id) do
    pid = SessionSupervisor.whereis(session_id)
    assert is_pid(pid)
    _state = :sys.get_state(pid)
    pid
  end

  defp unique_session_id do
    "session-#{System.unique_integer([:positive])}"
  end
end
