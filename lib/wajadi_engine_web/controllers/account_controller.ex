defmodule WajadiEngineWeb.AccountController do
  @moduledoc """
  Account-scoped management API for stores, catalog, personality, and sessions.
  """

  use WajadiEngineWeb, :controller

  require Logger

  alias WajadiEngine.Accounts
  alias WajadiEngine.Stores
  alias WajadiEngine.WhatsApp
  alias WajadiEngine.WhatsApp.SessionSupervisor
  alias WajadiEngineWeb.AccountJSON

  def index_stores(conn, params) do
    with {:ok, account} <- authenticate_account(conn, params) do
      render_success(
        conn,
        200,
        "List of stores",
        AccountJSON.stores(%{stores: Stores.list_stores(account)})
      )
    end
  end

  def create_store(conn, params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store} <- Stores.create_store(account, body_params(params)) do
      render_success(conn, 201, "Store created", AccountJSON.store(store))
    end
  end

  def update_store(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, store} <- Stores.update_store(account, store_id, body_params(params)) do
      render_success(conn, 200, "Store updated", AccountJSON.store(store))
    end
  end

  def archive_store(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, store} <- Stores.archive_store(account, store_id) do
      render_success(conn, 200, "Store archived", AccountJSON.store(store))
    end
  end

  def restore_store(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, store} <- Stores.restore_store(account, store_id) do
      render_success(conn, 200, "Store restored", AccountJSON.store(store))
    end
  end

  def show_personality(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, prompt} <- Stores.get_effective_personality(account, store_id) do
      render_success(conn, 200, "Store personality", AccountJSON.personality(%{prompt: prompt}))
    end
  end

  def upsert_personality(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, personality} <- Stores.upsert_personality(account, store_id, body_params(params)) do
      render_success(conn, 200, "Store personality saved", AccountJSON.personality(personality))
    end
  end

  def index_products(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, products} <- Stores.list_products(account, store_id) do
      render_success(conn, 200, "List of products", AccountJSON.products(%{products: products}))
    end
  end

  def create_product(conn, %{"store_id" => store_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, product} <- Stores.create_product(account, store_id, body_params(params)) do
      render_success(conn, 201, "Product created", AccountJSON.product(product))
    end
  end

  def update_product(conn, %{"store_id" => store_id, "id" => product_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, product_id} <- parse_integer(product_id),
         {:ok, product} <-
           Stores.update_product(account, store_id, product_id, body_params(params)) do
      render_success(conn, 200, "Product updated", AccountJSON.product(product))
    end
  end

  def archive_product(conn, %{"store_id" => store_id, "id" => product_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, store_id} <- parse_integer(store_id),
         {:ok, product_id} <- parse_integer(product_id),
         {:ok, product} <- Stores.archive_product(account, store_id, product_id) do
      render_success(conn, 200, "Product archived", AccountJSON.product(product))
    end
  end

  def move_session(conn, %{"session_id" => session_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, target_store_id} <- fetch_target_store_id(params),
         {:ok, session} <- WhatsApp.move_session(account, session_id, target_store_id) do
      render_success(conn, 200, "Session moved", AccountJSON.session(session))
    end
  end

  def archive_session(conn, %{"session_id" => session_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, session} <- WhatsApp.fetch_session_for_account(account, session_id),
         :ok <- SessionSupervisor.stop_session(session.session_id),
         {:ok, archived} <- WhatsApp.archive_session(account, session.session_id) do
      render_success(conn, 200, "Session archived", AccountJSON.session(archived))
    end
  end

  def restore_session(conn, %{"session_id" => session_id} = params) do
    with {:ok, account} <- authenticate_account(conn, params),
         {:ok, session} <- WhatsApp.restore_session(account, session_id) do
      render_success(
        conn,
        200,
        "Session restored; fresh QR pairing required",
        AccountJSON.restored_session(session)
      )
    end
  end

  defp authenticate_account(conn, %{"account_id" => account_id}) do
    with {:ok, account_id} <- parse_integer(account_id),
         {:ok, principal} <- fetch_principal(conn),
         {:ok, account} <- Accounts.fetch_account(account_id),
         :ok <- authorize_account(principal, account) do
      {:ok, account}
    end
  end

  defp fetch_principal(conn) do
    case get_req_header(conn, "x-account-email") do
      [email | _rest] -> Accounts.fetch_account_by_email(email)
      [] -> {:error, :unauthenticated}
    end
  end

  defp authorize_account(%{id: id}, %{id: id}), do: :ok
  defp authorize_account(_principal, _account), do: {:error, :not_found}

  defp fetch_target_store_id(params) do
    params
    |> body_params()
    |> Map.get("store_id")
    |> case do
      nil -> {:error, :missing_store_id}
      store_id -> parse_integer(store_id)
    end
  end

  defp body_params(params), do: Map.get(params, "_json", Map.drop(params, route_param_keys()))

  defp route_param_keys do
    ["account_id", "session_id", "id", "controller", "action"]
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :invalid_id}
    end
  end

  defp parse_integer(_value), do: {:error, :invalid_id}

  defp render_success(conn, status, message, data) do
    conn
    |> put_status(status)
    |> render(:success, message: message, data: data)
  end

  defp render_error(conn, status, message, error) do
    conn
    |> put_status(status)
    |> render(:error, message: message, error: error)
  end

  defp render_server_error(conn, source, reason) do
    Logger.error("Account controller error", source: source, reason: safe_reason(reason))

    conn
    |> put_status(500)
    |> render(:error, message: "Internal Server Error", error: nil)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp safe_reason(%Ecto.Changeset{}), do: :changeset_invalid
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_tuple(reason), do: elem(reason, 0)
  defp safe_reason(_reason), do: :unknown_reason

  defp handle_error(conn, {:error, %Ecto.Changeset{} = changeset}) do
    render_error(conn, 400, "Validation failed", %{errors: changeset_errors(changeset)})
  end

  defp handle_error(conn, {:error, :unauthenticated}) do
    render_error(conn, 401, "Authentication required", nil)
  end

  defp handle_error(conn, {:error, :not_found}) do
    render_error(conn, 404, "Resource not found", nil)
  end

  defp handle_error(conn, {:error, :store_in_use}) do
    render_error(conn, 409, "Store has a non-archived session", nil)
  end

  defp handle_error(conn, {:error, :store_occupied}) do
    render_error(conn, 409, "Target store already has a non-archived session", nil)
  end

  defp handle_error(conn, {:error, :store_not_available}) do
    render_error(conn, 409, "Store is not available", nil)
  end

  defp handle_error(conn, {:error, :purge_deadline_passed}) do
    render_error(conn, 410, "Archive purge deadline passed", nil)
  end

  defp handle_error(conn, {:error, :missing_store_id}) do
    render_error(conn, 400, "target store_id is required", nil)
  end

  defp handle_error(conn, {:error, :invalid_id}) do
    render_error(conn, 400, "Invalid identifier", nil)
  end

  defp handle_error(conn, {:error, reason}) do
    render_server_error(conn, "account.management", reason)
  end

  def action(conn, _opts) do
    apply(__MODULE__, action_name(conn), [conn, conn.params])
  catch
    :throw, reason -> handle_error(conn, reason)
  else
    %Plug.Conn{} = conn -> conn
    {:error, _reason} = error -> handle_error(conn, error)
  end
end
