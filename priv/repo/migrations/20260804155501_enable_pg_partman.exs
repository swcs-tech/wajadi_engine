defmodule WajadiEngine.Repo.Migrations.EnablePgPartman do
  use Ecto.Migration

  @enable_env "WAJADI_ENABLE_PG_PARTMAN_MIGRATION"

  def up do
    if enabled?() do
      execute("CREATE SCHEMA IF NOT EXISTS partman")
      execute("CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman")
      execute("SELECT extversion FROM pg_extension WHERE extname = 'pg_partman'")
    end
  end

  def down do
    if enabled?() do
      execute("DROP EXTENSION IF EXISTS pg_partman")
      execute("DROP SCHEMA IF EXISTS partman")
    end
  end

  defp enabled?, do: System.get_env(@enable_env) == "true"
end
