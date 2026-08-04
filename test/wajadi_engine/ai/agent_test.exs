defmodule WajadiEngine.AI.AgentTest do
  use WajadiEngine.DataCase

  import WajadiEngine.AccountsFixtures

  @arabica_image_url "https://pub-5d68f1fcb9ee47fcb3952ef6a2d5f2d5.r2.dev/store/product/arabica.jpg"

  alias Amarula.Protocol.Auth.AuthUtils
  alias WajadiEngine.AI
  alias WajadiEngine.AI.Agent
  alias WajadiEngine.ProductCatalog
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.SessionSupervisor

  describe "model/1" do
    test "builds an OpenAI-compatible 9Router model from runtime config" do
      config = %{
        base_url: "http://router.test/v1",
        endpoint: "http://router.test/v1/chat/completions",
        api_key: "test-key",
        model: "test-model",
        receive_timeout: 12_000
      }

      model = Agent.model(config: config, temperature: 1.0)

      assert model.endpoint == "http://router.test/v1/chat/completions"
      assert model.api_key == "test-key"
      assert model.model == "test-model"
      assert model.temperature == 0.0
      assert model.receive_timeout == 12_000
      assert model.parallel_tool_calls == false
      refute Map.has_key?(model, :top_p)
    end
  end

  describe "tools/0" do
    test "defaults to read-only auto-reply tools" do
      names = Agent.tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["get_product_list"]
    end

    test "get_product_list returns store-scoped products" do
      %{context: context, arabica: arabica} = catalog_fixture()
      tool = tool!("get_product_list")

      assert {:ok, message, processed_content} = tool.function.(%{}, context)
      assert %{"products" => products, "total" => 3} = Jason.decode!(message)

      assert Enum.any?(products, fn product ->
               product["id"] == arabica.id and
                 product["image_url"] == @arabica_image_url
             end)

      assert processed_content.total == 3
      assert Enum.any?(processed_content.products, &(&1.id == arabica.id))
    end

    test "get_product_list filters structured products by natural-language query" do
      %{context: context, arabica: arabica} = catalog_fixture()
      tool = tool!("get_product_list")

      assert {:ok, message, %{products: [product], total: 1}} =
               tool.function.(%{"query" => "Apakah ada foto kopi arabica?"}, context)

      assert product.id == arabica.id
      assert product.image_url == @arabica_image_url
      assert %{"total" => 1} = Jason.decode!(message)
    end

    test "get_product_list keeps full catalog for a generic natural-language query" do
      %{context: context} = catalog_fixture()
      tool = tool!("get_product_list")

      assert {:ok, message, %{total: 3}} =
               tool.function.(%{"query" => "Ada produk apa saja min?"}, context)

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

  describe "system_prompt/2" do
    test "includes base prompt, bounded store personality, and final-reply safety policy" do
      session = session_fixture()
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)
      long_personality = String.duplicate("Coffee specialist ", 200)

      assert {:ok, _personality} =
               Stores.upsert_personality(account, session.store_id, %{prompt: long_personality})

      prompt = Agent.system_prompt(account.id, session.store_id)

      assert prompt =~ "asisten WhatsApp"
      assert prompt =~ "Gunakan hanya konteks toko tepercaya"
      assert prompt =~ "Coffee specialist"
      assert prompt =~ "final reply"
      assert prompt =~ "get_product_list"
      assert String.length(prompt) < String.length(long_personality) + 2_000
    end
  end

  describe "ProductCatalog" do
    test "returns structured products with image URL" do
      %{context: context, arabica: arabica} = catalog_fixture()

      assert %{products: products, total: 3} =
               ProductCatalog.structured_products(
                 ProductCatalog.list_products(context.account_id, context.store_id)
               )

      assert %{id: arabica_id, image_url: @arabica_image_url} =
               Enum.find(products, &(&1.id == arabica.id))

      assert arabica_id == arabica.id
    end

    test "formats structured products for WhatsApp text" do
      %{context: context} = catalog_fixture()

      formatted =
        context.account_id
        |> ProductCatalog.list_products(context.store_id)
        |> ProductCatalog.format_products()

      assert formatted =~
               "1. Kopi Arabica 250g - Rp75.000 - Stok: 10 - Rasa fruity dengan acidity ringan."
    end

    test "ignores generic words when searching natural-language catalog requests" do
      %{context: context} = catalog_fixture()

      products =
        ProductCatalog.search_products(
          context.account_id,
          context.store_id,
          "Ada produk apa saja min?"
        )

      assert %{total: 3} = ProductCatalog.structured_products(products)
    end

    test "ignores image-request words when searching product image requests" do
      %{context: context, arabica: arabica} = catalog_fixture()

      products =
        ProductCatalog.search_products(
          context.account_id,
          context.store_id,
          "Apakah ada foto kopi arabica?"
        )

      assert %{products: [%{id: arabica_id}], total: 1} =
               ProductCatalog.structured_products(products)

      assert arabica_id == arabica.id
    end

    test "does not expose products from another store" do
      %{context: context} = catalog_fixture()
      other_session = session_fixture("other@example.com")

      assert ProductCatalog.list_products(other_session.account_id, other_session.store_id) == []

      assert [_, _, _] =
               ProductCatalog.list_products(context.account_id, context.store_id)
    end
  end

  describe "AI.config/0" do
    test "normalizes base URL into chat completions endpoint" do
      config = AI.config()

      assert config.base_url == "http://localhost:20128/v1"
      assert config.endpoint == "http://localhost:20128/v1/chat/completions"
      assert config.api_key == "dummy-key"
      assert config.model == "gpt-4o"
      refute Map.has_key?(config, :temperature)
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

  defp catalog_fixture do
    session = session_fixture()
    account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)
    store = Repo.get!(Store, session.store_id)

    arabica =
      product_fixture(account, store, %{
        name: "Kopi Arabica 250g",
        sku: "ARABICA-250",
        description: "Rasa fruity dengan acidity ringan.",
        price: "75000.00",
        stock_quantity: 10,
        image_url: @arabica_image_url,
        sort_order: 1
      })

    _robusta =
      product_fixture(account, store, %{
        name: "Kopi Robusta 250g",
        description: "Body kuat dengan rasa cokelat dan pahit seimbang.",
        price: "55000.00",
        stock_quantity: 8,
        sort_order: 2
      })

    _drip_bag =
      product_fixture(account, store, %{
        name: "Drip Bag Coffee 10 pcs",
        description: "Praktis untuk seduh kopi tanpa alat espresso.",
        price: "60000.00",
        stock_quantity: 5,
        sort_order: 3
      })

    %{
      arabica: arabica,
      context: %{
        account_id: session.account_id,
        store_id: session.store_id,
        session_id: session.session_id
      }
    }
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
