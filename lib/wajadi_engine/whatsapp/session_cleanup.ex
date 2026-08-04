defmodule WajadiEngine.WhatsApp.SessionCleanup do
  @moduledoc """
  Bounded, retryable cleanup for expired archived WhatsApp sessions.
  """

  import Ecto.Query

  require Logger

  alias WajadiEngine.Repo
  alias WajadiEngine.Stores.Store
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.ChatHistory
  alias WajadiEngine.WhatsApp.Session

  @default_batch_size 100
  @max_batch_size 1_000

  @type summary :: %{
          selected: non_neg_integer(),
          purged: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec purge_once(keyword()) :: summary()
  def purge_once(opts \\ []) do
    batch_size = opts |> Keyword.get(:batch_size, @default_batch_size) |> clamp_batch_size()
    current_time = Keyword.get(opts, :now, now())

    :telemetry.span(
      [:wajadi_engine, :whatsapp, :session_cleanup],
      %{batch_size: batch_size},
      fn ->
        summary = do_purge_once(batch_size, current_time)
        :telemetry.execute([:wajadi_engine, :whatsapp, :session_cleanup, :result], summary, %{})
        {summary, summary}
      end
    )
  end

  defp do_purge_once(batch_size, current_time) do
    session_ids =
      Session
      |> where(
        [session],
        not is_nil(session.archived_at) and session.purge_at <= ^current_time
      )
      |> order_by([session], asc: session.purge_at, asc: session.id)
      |> limit(^batch_size)
      |> select([session], session.id)
      |> Repo.all()

    initial = %{selected: length(session_ids), purged: 0, skipped: 0, failed: 0}

    Enum.reduce(session_ids, initial, fn session_id, summary ->
      case purge_session(session_id, current_time) do
        :purged ->
          Map.update!(summary, :purged, &(&1 + 1))

        :skipped ->
          Map.update!(summary, :skipped, &(&1 + 1))

        {:error, reason} ->
          Logger.warning("Archived WhatsApp session purge failed",
            session_row_id: session_id,
            reason: safe_reason(reason)
          )

          Map.update!(summary, :failed, &(&1 + 1))
      end
    end)
  end

  defp purge_session(session_id, current_time) do
    Repo.transaction(fn ->
      query =
        Session
        |> where([session], session.id == ^session_id)
        |> lock("FOR UPDATE")

      case Repo.one(query) do
        %Session{} = session -> purge_locked_session(session, current_time)
        nil -> Repo.rollback(:skip)
      end
    end)
    |> case do
      {:ok, :purged} -> :purged
      {:error, :skip} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp purge_locked_session(%Session{} = session, current_time) do
    if purge_eligible?(session, current_time) do
      AuthState
      |> where([auth_state], auth_state.session_id == ^session.session_id)
      |> Repo.delete_all()

      store_id = session.store_id
      Repo.delete!(session)
      maybe_delete_store(store_id, current_time)
      :purged
    else
      Repo.rollback(:skip)
    end
  end

  defp purge_eligible?(%Session{archived_at: %DateTime{}, purge_at: %DateTime{} = purge_at}, now) do
    DateTime.compare(purge_at, now) in [:lt, :eq]
  end

  defp purge_eligible?(_session, _now), do: false

  defp maybe_delete_store(store_id, current_time) do
    query = Store |> where([store], store.id == ^store_id) |> lock("FOR UPDATE")

    case Repo.one(query) do
      %Store{} = store -> maybe_delete_locked_store(store, current_time)
      nil -> :ok
    end
  end

  defp maybe_delete_locked_store(
         %Store{archived_at: %DateTime{}, purge_at: %DateTime{} = purge_at} = store,
         current_time
       ) do
    eligible? = DateTime.compare(purge_at, current_time) in [:lt, :eq]

    if eligible? and not store_has_sessions?(store.id) and not store_has_history?(store.id) do
      Repo.delete!(store)
    end

    :ok
  end

  defp maybe_delete_locked_store(_store, _current_time), do: :ok

  defp store_has_sessions?(store_id) do
    Session |> where([session], session.store_id == ^store_id) |> Repo.exists?()
  end

  defp store_has_history?(store_id) do
    ChatHistory |> where([history], history.store_id == ^store_id) |> Repo.exists?()
  end

  defp clamp_batch_size(value) when is_integer(value) and value > 0,
    do: min(value, @max_batch_size)

  defp clamp_batch_size(_value), do: @default_batch_size

  defp safe_reason(%Ecto.Changeset{}), do: :changeset_invalid
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(%module{}) when is_atom(module), do: module
  defp safe_reason(_reason), do: :unknown_reason

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
