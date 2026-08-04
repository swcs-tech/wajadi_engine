defmodule WajadiEngine.Accounts do
  @moduledoc """
  Account lookup boundary for management APIs.
  """

  alias WajadiEngine.Accounts.Account
  alias WajadiEngine.Repo

  @spec fetch_account(integer()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch_account(account_id) when is_integer(account_id) do
    case Repo.get(Account, account_id) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  @spec fetch_account_by_email(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch_account_by_email(email) when is_binary(email) do
    case Repo.get_by(Account, email: Account.normalize_email(email)) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end
end
