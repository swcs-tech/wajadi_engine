defmodule WajadiEngine.WhatsApp.SessionServerTest do
  use WajadiEngine.DataCase

  import Ecto.Query
  import WajadiEngine.AccountsFixtures

  alias Amarula.Address
  alias Amarula.Protocol.Auth.AuthUtils
  alias Amarula.Protocol.Proto
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Product
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.ChatHistory
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

    test "connection interruption keeps active session restorable" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      send(pid, {:amarula, :connection_update, %{connection: :closed}})
      :sys.get_state(pid)

      assert {:ok, updated} = WhatsApp.fetch_session(session.session_id)
      assert updated.status == "connecting"
      assert updated.is_active == true
      assert is_nil(updated.qr)
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
                 amarula_config: offline_config()
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
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, conn_pid} = SessionServer.connect(pid)
      assert is_pid(conn_pid)
      assert {:ok, msg_id} = SessionServer.send_reply(pid, "628123@s.whatsapp.net", "hi")
      assert is_binary(msg_id)
    end

    test "incoming text message inserts received chat history" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, conn_pid} = SessionServer.connect(pid)
      Amarula.Testing.deliver_text(conn_pid, from: "628123@s.whatsapp.net", text: "hello")
      :sys.get_state(conn_pid)
      :sys.get_state(pid)

      assert [chat_history] = chat_histories(session.session_id)
      assert chat_history.from == "628123@s.whatsapp.net"
      assert chat_history.to == "10000000000@s.whatsapp.net"
      assert chat_history.from_me == false
      assert chat_history.body == "hello"
      assert chat_history.type == "text"
      assert chat_history.status == "received"
    end

    test "ping skips AI and logs sent pong to hardcoded PN" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.SuccessAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, session} = WhatsApp.fetch_session(session.session_id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(content: "  PING  ")]}})
      :sys.get_state(pid)

      assert [incoming, outgoing] = chat_histories(session.session_id)
      assert incoming.from_me == false
      assert incoming.body == "  PING  "
      assert incoming.status == "received"
      assert outgoing.from_me == true
      assert outgoing.to == "6282111096953@s.whatsapp.net"
      assert outgoing.body == "pong"
      assert outgoing.type == "text"
      assert outgoing.status == "sent"
      assert outgoing.error == nil
    end

    test "incoming from_me messages are skipped" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: %{offline: true, connection_state: :connected}
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(from_me: true)]}})
      :sys.get_state(pid)

      assert chat_histories(session.session_id) == []
    end

    test "successful reply logs one sent outgoing row" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, msg_id} = SessionServer.send_reply(pid, "628123", "hi")
      assert is_binary(msg_id)

      assert [chat_history] = chat_histories(session.session_id)
      assert chat_history.from == "10000000000@s.whatsapp.net"
      assert chat_history.to == "628123@s.whatsapp.net"
      assert chat_history.from_me == true
      assert chat_history.body == "hi"
      assert chat_history.type == "text"
      assert chat_history.status == "sent"
      assert chat_history.error == nil
    end

    test "failed reply logs failed outgoing row" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:error, :not_connected} = SessionServer.send_reply(pid, "628123", "hi")

      assert [chat_history] = chat_histories(session.session_id)
      assert chat_history.to == "628123@s.whatsapp.net"
      assert chat_history.from_me == true
      assert chat_history.status == "failed"
      assert chat_history.error =~ ":not_connected"
    end

    test "paused session logs incoming but skips AI reply" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.SuccessAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, _paused} = SessionServer.pause(pid)

      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(content: "hello")]}})
      :sys.get_state(pid)

      assert [incoming] = chat_histories(session.session_id)
      assert incoming.from_me == false
      assert incoming.body == "hello"
    end

    test "connected session calls AI and logs outgoing reply once" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.SuccessAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, session} = WhatsApp.fetch_session(session.session_id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)
      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(content: "hello")]}})
      :sys.get_state(pid)

      assert [incoming, outgoing] = chat_histories(session.session_id)
      assert incoming.from_me == false
      assert incoming.body == "hello"
      assert incoming.status == "received"
      assert outgoing.from_me == true
      assert outgoing.body == "AI reply to hello"
      assert outgoing.status == "sent"
    end

    test "runtime passes trusted current store context to AI after movement" do
      receiver_name = WajadiEngine.FakeAI.ContextAgent.receiver_name()
      Process.register(self(), receiver_name)
      on_exit(fn -> if Process.whereis(receiver_name), do: Process.unregister(receiver_name) end)

      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)
      assert {:ok, target_store} = Stores.create_store(account, %{name: "Target"})
      assert {:ok, moved} = WhatsApp.move_session(account, session.session_id, target_store.id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(moved)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.ContextAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, session} = WhatsApp.fetch_session(session.session_id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)
      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(content: "hello")]}})
      :sys.get_state(pid)

      assert_receive {:ai_context, context, "hello"}

      assert context == %{
               account_id: account.id,
               store_id: target_store.id,
               session_id: session.session_id
             }

      assert [incoming, outgoing] = chat_histories(session.session_id)
      assert incoming.store_id == target_store.id
      assert outgoing.store_id == target_store.id
    end

    test "product image request sends image media when one matching product has image URL" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)
      store = Repo.get!(WajadiEngine.Stores.Store, session.store_id)

      product =
        product_fixture(account, store, %{
          name: "Kopi Arabica 250g",
          price: "75000.00",
          stock_quantity: 10,
          description: "Rasa fruity dengan acidity ringan."
        })

      Product
      |> where([stored_product], stored_product.id == ^product.id)
      |> Repo.update_all(set: [image_url: "data:image/jpeg;base64,AAEC"])

      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.SuccessAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, session} = WhatsApp.fetch_session(session.session_id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      send(
        pid,
        {:amarula, :messages_upsert,
         %{messages: [text_msg(content: "Apakah ada foto kopi arabica?")]}}
      )

      :sys.get_state(pid)

      assert [incoming, outgoing] = chat_histories(session.session_id)
      assert incoming.from_me == false
      assert incoming.body == "Apakah ada foto kopi arabica?"
      assert outgoing.from_me == true
      assert outgoing.type == "image"
      assert outgoing.body =~ "Kopi Arabica 250g"
      assert outgoing.status in ["sent", "failed"]
    end

    test "AI error keeps session process alive and skips outgoing reply" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 ai_agent: WajadiEngine.FakeAI.ErrorAgent,
                 ai_async?: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = SessionServer.connect(pid)
      assert {:ok, session} = WhatsApp.fetch_session(session.session_id)
      assert {:ok, _session} = WhatsApp.mark_session_connected(session)
      send(pid, {:amarula, :messages_upsert, %{messages: [text_msg(content: "hello")]}})

      assert %SessionServer{} = :sys.get_state(pid)
      assert [incoming] = chat_histories(session.session_id)
      assert incoming.from_me == false
      assert incoming.body == "hello"
    end

    test "delete archives session and stops runtime process" do
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
      assert Repo.get!(WajadiEngine.WhatsApp.Session, session.id).archived_at
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

      assert {:ok, _auth_state} =
               WhatsApp.create_auth_state(%{
                 session_id: active.session_id,
                 type: "creds",
                 key: "creds",
                 value: %{"id" => "1"}
               })

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

  defp chat_histories(session_id) do
    ChatHistory
    |> where([chat_history], chat_history.session_id == ^session_id)
    |> order_by([chat_history], asc: chat_history.inserted_at)
    |> Repo.all()
  end

  defp offline_config do
    %{
      offline: true,
      connection_state: :connected,
      auth:
        Map.put(AuthUtils.init_auth_creds(), :me, %{
          id: "10000000000@s.whatsapp.net",
          name: "Test Bot"
        })
    }
  end

  defp text_msg(opts) do
    from_me? = Keyword.get(opts, :from_me, false)
    content = Keyword.get(opts, :content, "own message")

    %Amarula.Msg{
      id: "msg-1",
      channel: Address.pn("628123"),
      from: Address.pn("628123"),
      to: Address.pn("10000000000"),
      from_me: from_me?,
      type: :text,
      content: content,
      raw: %Proto.Message{}
    }
  end
end
