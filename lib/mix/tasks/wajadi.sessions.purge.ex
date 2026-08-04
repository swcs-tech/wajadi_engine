defmodule Mix.Tasks.Wajadi.Sessions.Purge do
  @moduledoc false

  use Mix.Task

  alias WajadiEngine.WhatsApp.SessionCleanup

  @shortdoc "Purges expired archived WhatsApp sessions"

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args, strict: [batch_size: :integer], aliases: [b: :batch_size])

    Mix.Task.run("app.start")

    summary = SessionCleanup.purge_once(batch_size: Keyword.get(opts, :batch_size, 100))

    Mix.shell().info(
      "selected=#{summary.selected} purged=#{summary.purged} " <>
        "skipped=#{summary.skipped} failed=#{summary.failed}"
    )

    if summary.failed > 0 do
      Mix.raise("One or more archived sessions could not be purged")
    end
  end
end
