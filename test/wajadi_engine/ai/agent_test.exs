defmodule WajadiEngine.AI.AgentTest do
  use WajadiEngine.DataCase

  @arabica_image_url "https://pub-5d68f1fcb9ee47fcb3952ef6a2d5f2d5.r2.dev/store/product/arabica.jpg"

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

      assert {:ok, message, processed_content} = tool.function.(%{}, %{})
      assert %{"products" => products, "total" => 3} = Jason.decode!(message)

      assert Enum.any?(products, fn product ->
               product["id"] == "kopi-arabica-250g" and
                 product["image_url"] == @arabica_image_url
             end)

      assert processed_content.total == 3
      assert Enum.any?(processed_content.products, &(&1.id == "kopi-arabica-250g"))
    end

    test "get_product_list filters structured products by natural-language query" do
      tool = tool!("get_product_list")

      assert {:ok, message, %{products: [product], total: 1}} =
               tool.function.(%{"query" => "Apakah ada foto kopi arabica?"}, %{})

      assert product.id == "kopi-arabica-250g"
      assert product.image_url == @arabica_image_url
      assert %{"total" => 1} = Jason.decode!(message)
    end

    test "get_product_list keeps full catalog for a generic natural-language query" do
      tool = tool!("get_product_list")

      assert {:ok, message, %{total: 3}} =
               tool.function.(%{"query" => "Ada produk apa saja min?"}, %{})

      assert %{"total" => 3} = Jason.decode!(message)
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
    test "returns structured products with image URL" do
      assert %{products: products, total: 3} =
               ProductCatalog.structured_products(ProductCatalog.list_products())

      assert %{id: "kopi-arabica-250g", image_url: @arabica_image_url} =
               Enum.find(products, &(&1.id == "kopi-arabica-250g"))
    end

    test "formats structured products for WhatsApp text" do
      formatted = ProductCatalog.format_products()

      assert formatted =~
               "1. Kopi Arabica 250g - Rp75.000 - Stok: tersedia - Rasa fruity dengan acidity ringan."
    end

    test "ignores generic words when searching natural-language catalog requests" do
      products = ProductCatalog.search_products("Ada produk apa saja min?")

      assert %{total: 3} = ProductCatalog.structured_products(products)
    end

    test "ignores image-request words when searching product image requests" do
      products = ProductCatalog.search_products("Apakah ada foto kopi arabica?")

      assert %{products: [%{id: "kopi-arabica-250g"}], total: 1} =
               ProductCatalog.structured_products(products)
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
