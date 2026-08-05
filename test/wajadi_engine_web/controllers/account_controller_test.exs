defmodule WajadiEngineWeb.AccountControllerTest do
  use WajadiEngineWeb.ConnCase

  import WajadiEngine.AccountsFixtures

  alias WajadiEngine.ProductCatalog
  alias WajadiEngine.Repo
  alias WajadiEngine.Stores.Product
  alias WajadiEngine.WhatsApp

  describe "authentication" do
    test "exposes account management routes" do
      account_routes =
        WajadiEngineWeb.Router.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/api/account/:account_id"))
        |> Enum.map(&{&1.verb, &1.path})
        |> Enum.sort()

      assert account_routes ==
               [
                 {:delete, "/api/account/:account_id/sessions/:session_id"},
                 {:delete, "/api/account/:account_id/stores/:store_id"},
                 {:delete, "/api/account/:account_id/stores/:store_id/products/:id"},
                 {:get, "/api/account/:account_id/stores"},
                 {:get, "/api/account/:account_id/stores/:store_id/personality"},
                 {:get, "/api/account/:account_id/stores/:store_id/products"},
                 {:patch, "/api/account/:account_id/sessions/:session_id/store"},
                 {:patch, "/api/account/:account_id/stores/:store_id"},
                 {:patch, "/api/account/:account_id/stores/:store_id/products/:id"},
                 {:post, "/api/account/:account_id/sessions/:session_id/restore"},
                 {:post, "/api/account/:account_id/stores"},
                 {:post, "/api/account/:account_id/stores/:store_id/products"},
                 {:post, "/api/account/:account_id/stores/:store_id/restore"},
                 {:put, "/api/account/:account_id/stores/:store_id/personality"}
               ]
    end

    test "requires account principal header", %{conn: conn} do
      account = account_fixture()

      response =
        conn
        |> get(~p"/api/account/#{account.id}/stores")
        |> json_response(401)

      assert response["success"] == false
      assert response["status"] == "error"
      assert response["message"] == "Authentication required"
      assert Map.has_key?(response, "error")
    end

    test "does not authorize from route account_id alone", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()

      response =
        conn
        |> auth(other_account)
        |> get(~p"/api/account/#{account.id}/stores")
        |> json_response(404)

      assert response["message"] == "Resource not found"
    end
  end

  describe "store management" do
    test "lists, creates, updates, archives, and restores account stores", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()
      visible = store_fixture(account, %{name: "Visible"})
      _hidden = store_fixture(other_account, %{name: "Hidden"})

      list_response =
        conn
        |> auth(account)
        |> get(~p"/api/account/#{account.id}/stores")
        |> json_response(200)

      assert [%{"id" => visible_id, "name" => "Visible"}] = list_response["data"]["stores"]
      assert visible_id == visible.id
      assert list_response["success"] == true
      assert list_response["status"] == "success"
      assert list_response["message"] == "List of stores"

      create_response =
        build_conn()
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/stores", %{name: "New Store"})
        |> json_response(201)

      assert create_response["message"] == "Store created"
      store_id = create_response["data"]["id"]

      update_response =
        build_conn()
        |> auth(account)
        |> patch(~p"/api/account/#{account.id}/stores/#{store_id}", %{name: "Renamed"})
        |> json_response(200)

      assert update_response["data"]["name"] == "Renamed"

      archive_response =
        build_conn()
        |> auth(account)
        |> delete(~p"/api/account/#{account.id}/stores/#{store_id}")
        |> json_response(200)

      assert archive_response["data"]["status"] == "archived"

      restore_response =
        build_conn()
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/stores/#{store_id}/restore")
        |> json_response(200)

      assert restore_response["data"]["status"] == "unassigned"
    end

    test "rejects archiving store with non-archived session", %{conn: conn} do
      session = session_fixture("owner@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)

      response =
        conn
        |> auth(account)
        |> delete(~p"/api/account/#{account.id}/stores/#{session.store_id}")
        |> json_response(409)

      assert response["message"] == "Store has a non-archived session"
    end
  end

  describe "personality management" do
    test "reads default and upserts custom prompt", %{conn: conn} do
      account = account_fixture()
      store = store_fixture(account)

      default_response =
        conn
        |> auth(account)
        |> get(~p"/api/account/#{account.id}/stores/#{store.id}/personality")
        |> json_response(200)

      assert default_response["data"]["prompt"] =~ "admin toko Wajadi"

      upsert_response =
        build_conn()
        |> auth(account)
        |> put(~p"/api/account/#{account.id}/stores/#{store.id}/personality", %{
          prompt: "  Specialist prompt  ",
          store_id: -1
        })
        |> json_response(200)

      assert upsert_response["data"]["store_id"] == store.id
      assert upsert_response["data"]["prompt"] == "Specialist prompt"
    end

    test "returns structured validation error for invalid prompt", %{conn: conn} do
      account = account_fixture()
      store = store_fixture(account)

      response =
        conn
        |> auth(account)
        |> put(~p"/api/account/#{account.id}/stores/#{store.id}/personality", %{prompt: " "})
        |> json_response(400)

      assert response["message"] == "Validation failed"
      assert response["error"]["errors"]["prompt"] == ["can't be blank"]
    end
  end

  describe "product management" do
    test "creates, lists, updates, archives, and hides product from AI catalog", %{conn: conn} do
      account = account_fixture()
      store = store_fixture(account)

      create_response =
        conn
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/stores/#{store.id}/products", %{
          name: "Kopi",
          sku: " kopi-1 ",
          price: "12000.00",
          currency: "IDR",
          stock_quantity: 5,
          availability: "in_stock",
          sort_order: 1
        })
        |> json_response(201)

      assert create_response["data"]["sku"] == "KOPI-1"
      assert create_response["data"]["price"] == "12000.00"
      product_id = create_response["data"]["id"]

      list_response =
        build_conn()
        |> auth(account)
        |> get(~p"/api/account/#{account.id}/stores/#{store.id}/products")
        |> json_response(200)

      assert [%{"id" => ^product_id}] = list_response["data"]["products"]

      update_response =
        build_conn()
        |> auth(account)
        |> patch(~p"/api/account/#{account.id}/stores/#{store.id}/products/#{product_id}", %{
          name: "Kopi Susu"
        })
        |> json_response(200)

      assert update_response["data"]["name"] == "Kopi Susu"

      archive_response =
        build_conn()
        |> auth(account)
        |> delete(~p"/api/account/#{account.id}/stores/#{store.id}/products/#{product_id}")
        |> json_response(200)

      assert archive_response["data"]["is_active"] == false
      assert Repo.get!(Product, product_id).is_active == false
      assert ProductCatalog.list_products(account.id, store.id) == []
    end

    test "rejects validation and cross-account product access", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()
      store = store_fixture(account)
      product = product_fixture(account, store)

      invalid_response =
        conn
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/stores/#{store.id}/products", %{
          name: "",
          price: "-1.00",
          availability: "missing"
        })
        |> json_response(400)

      assert invalid_response["message"] == "Validation failed"
      assert Map.has_key?(invalid_response["error"]["errors"], "price")

      cross_response =
        build_conn()
        |> auth(other_account)
        |> patch(
          ~p"/api/account/#{other_account.id}/stores/#{store.id}/products/#{product.id}",
          %{
            name: "Nope"
          }
        )
        |> json_response(404)

      assert cross_response["message"] == "Resource not found"
    end
  end

  describe "session management" do
    test "one account can own multiple stores and paired sessions", %{conn: conn} do
      first = session_fixture("multi@example.com")
      second = session_fixture("multi@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, first.account_id)

      response =
        conn
        |> auth(account)
        |> get(~p"/api/account/#{account.id}/stores")
        |> json_response(200)

      store_ids = Enum.map(response["data"]["stores"], & &1["id"])

      assert first.account_id == second.account_id
      assert first.store_id in store_ids
      assert second.store_id in store_ids
      assert first.store_id != second.store_id
    end

    test "moves session into an owned unassigned store", %{conn: conn} do
      session = session_fixture("owner@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)
      target_store = store_fixture(account, %{name: "Target"})

      response =
        conn
        |> auth(account)
        |> patch(~p"/api/account/#{account.id}/sessions/#{session.session_id}/store", %{
          store_id: target_store.id
        })
        |> json_response(200)

      assert response["message"] == "Session moved"
      assert response["data"]["store_id"] == target_store.id
    end

    test "rejects movement into occupied store", %{conn: conn} do
      first = session_fixture("owner@example.com")
      occupied = session_fixture("owner@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, first.account_id)

      response =
        conn
        |> auth(account)
        |> patch(~p"/api/account/#{account.id}/sessions/#{first.session_id}/store", %{
          store_id: occupied.store_id
        })
        |> json_response(409)

      assert response["message"] == "Target store already has a non-archived session"
    end

    test "archives and restores session without auth state", %{conn: conn} do
      session = session_fixture("owner@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)

      assert {:ok, _auth_state} =
               WhatsApp.create_auth_state(%{
                 session_id: session.session_id,
                 type: "creds",
                 key: "creds",
                 value: %{"id" => "secret"}
               })

      archive_response =
        conn
        |> auth(account)
        |> delete(~p"/api/account/#{account.id}/sessions/#{session.session_id}")
        |> json_response(200)

      assert archive_response["message"] == "Session archived"
      assert archive_response["data"]["archived_at"]
      assert WhatsApp.list_auth_state_metadata(session.session_id) == []

      restore_response =
        build_conn()
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/sessions/#{session.session_id}/restore")
        |> json_response(200)

      assert restore_response["message"] == "Session restored; fresh QR pairing required"
      assert restore_response["data"]["requires_qr_pairing"] == true
      assert restore_response["data"]["status"] == "disconnected"
      assert WhatsApp.list_auth_state_metadata(session.session_id) == []
    end

    test "returns gone when restore passes purge deadline", %{conn: conn} do
      session = session_fixture("owner@example.com")
      account = Repo.get!(WajadiEngine.Accounts.Account, session.account_id)

      assert {:ok, _archived} =
               WhatsApp.archive_session(account, session.session_id, ~U[2026-01-01 00:00:00Z])

      response =
        conn
        |> auth(account)
        |> post(~p"/api/account/#{account.id}/sessions/#{session.session_id}/restore")
        |> json_response(410)

      assert response["message"] == "Archive purge deadline passed"
    end
  end

  defp auth(conn, account) do
    put_req_header(conn, "x-account-email", account.email)
  end
end
