defmodule WajadiEngine.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :email, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accounts, [:email], name: :accounts_email_index)
  end
end
