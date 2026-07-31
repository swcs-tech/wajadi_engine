defmodule WajadiEngine.AI.AgentTest do
  use WajadiEngine.DataCase

  alias Amarula.Protocol.Auth.AuthUtils
  alias WajadiEngine.AI
  alias WajadiEngine.AI.Agent
  alias WajadiEngine.ProductCatalog
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.SessionSupervisor

  describe "model/1" do
    test "builds an OpenAI-compatible 9Router model from runtime config" do
      config = %{
        base_url: "http://router.test/v1",
        endpoint: "http://router.test/v1/chat/completions",
        api_key: "test-key",
        model: "test-model",
        temperature: 0.2,
        receive_timeout: 12_000
      }

      model = Agent.model(config: config)

      assert model.endpoint == "http://router.test/v1/chat/completions"
      assert model.api_key == "test-key"
      assert model.model == "test-model"
      assert model.temperature == 0.2
      assert model.receive_timeout == 12_000
      assert model.parallel_tool_calls == false
    end
  end

  describe "tools/0" do
    test "defaults to read-only auto-reply tools" do
      names = Agent.tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["get_product_list"]
    end

    test "get_product_list returns configured products" do
      tool = tool!("get_product_list")

      assert {:ok, message} = tool.function.(%{}, %{})

      assert message =~ "Produk Test"
      assert message =~ "Rp10.000"
      assert message =~ "ready"
    end
  end

  describe "action_tools/0" do
    test "keeps WhatsApp send tools out of default auto-reply tools" do
      names = Agent.action_tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == [
               "reply_whatsapp_message",
               "send_whatsapp_image",
               "send_whatsapp_message"
             ]

      refute Enum.any?(Agent.tools(), &(&1.name in names))
    end

    test "send_whatsapp_message reports inactive session" do
      tool = action_tool!("send_whatsapp_message")

      assert {:ok, message} =
               tool.function.(
                 %{"sessionId" => "missing-session", "to" => "628123", "message" => "hi"},
                 %{}
               )

      assert message == "Failed: Session \"missing-session\" is not active or connected."
    end

    test "send_whatsapp_message sends text through active runtime without chat-history logging" do
      session_id = unique_session_id()
      assert {:ok, session} = WhatsApp.create_session("user-1", %{session_id: session_id})

      assert {:ok, pid} =
               SessionSupervisor.start_session(session.user_id, session.session_id,
                 connect: false,
                 amarula_config: offline_config()
               )

      on_exit(fn -> SessionSupervisor.stop_session(session.session_id) end)

      assert {:ok, _conn_pid} = WajadiEngine.WhatsApp.SessionServer.connect(pid)
      tool = action_tool!("send_whatsapp_message")

      assert {:ok, message} =
               tool.function.(
                 %{"sessionId" => session.session_id, "to" => "628123", "message" => "hi"},
                 %{}
               )

      assert message == "Successfully sent text message to 628123"
      assert WhatsApp.count_chat_histories(session.session_id) == 0
    end
  end

  describe "system_prompt/0" do
    test "includes configured personality and final-reply safety policy" do
      prompt = Agent.system_prompt()

      assert prompt =~ "admin toko Wajadi"
      assert prompt =~ "final reply"
      assert prompt =~ "get_product_list"
    end
  end

  describe "ProductCatalog" do
    test "formats configured products" do
      assert ProductCatalog.format_products() == "1. Produk Test - Rp10.000 - ready"
    end
  end

  describe "AI.config/0" do
    test "normalizes base URL into chat completions endpoint" do
      config = AI.config()

      assert config.base_url == "http://localhost:20128/v1"
      assert config.endpoint == "http://localhost:20128/v1/chat/completions"
      assert config.api_key == "dummy-key"
      assert config.model == "gpt-4o"
    end
  end

  defp tool!(name) do
    Enum.find(Agent.tools(), &(&1.name == name))
  end

  defp action_tool!(name) do
    Enum.find(Agent.action_tools(), &(&1.name == name))
  end

  defp unique_session_id do
    "session-#{System.unique_integer([:positive])}"
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
end
