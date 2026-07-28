defmodule WajadiEngine.WhatsApp.Storage.Postgres do
  @moduledoc """
  PostgreSQL-backed Amarula storage adapter using `wa_auth_states` rows.
  """

  @behaviour Amarula.Storage

  import Ecto.Query

  require Logger

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.Storage.Codec

  @namespace_types %{
    creds: "creds",
    session: "session",
    sender_key: "sender-key",
    app_state_sync_key: "app-state-sync-key",
    app_state_version: "app-state-version",
    lid_mapping: "lid-mapping",
    device_list: "device-list"
  }

  @impl true
  def new(opts) do
    %{repo: Keyword.get(opts, :repo, Repo)}
  end

  @impl true
  def get(%{repo: repo}, profile, namespace, key) do
    with {:ok, type, row_key} <- row_identity(namespace, key) do
      AuthState
      |> where(
        [auth_state],
        auth_state.session_id == ^profile_id(profile) and auth_state.type == ^type and
          auth_state.key == ^row_key
      )
      |> repo.one()
      |> case do
        %AuthState{encoding: encoding, value: value} ->
          case Codec.decode(encoding, value) do
            {:ok, decoded} ->
              {:ok, decoded}

            {:error, reason} ->
              Logger.warning("Postgres storage decode failed",
                session_id: profile_id(profile),
                type: type,
                key: row_key,
                reason: inspect(reason)
              )

              :error
          end

        nil ->
          :error
      end
    else
      {:error, _reason} -> :error
    end
  end

  @impl true
  def put(%{repo: repo}, profile, namespace, key, value) do
    with {:ok, type, row_key} <- row_identity(namespace, key) do
      {encoding, encoded_value} = Codec.encode(value)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        session_id: profile_id(profile),
        type: type,
        key: row_key,
        value: encoded_value,
        encoding: encoding
      }

      %AuthState{}
      |> AuthState.create_changeset(attrs)
      |> repo.insert(
        on_conflict: [set: [value: encoded_value, encoding: encoding, updated_at: now]],
        conflict_target: [:session_id, :type, :key]
      )
      |> case do
        {:ok, _auth_state} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(%{repo: repo}, profile, namespace, key) do
    with {:ok, type, row_key} <- row_identity(namespace, key) do
      AuthState
      |> where(
        [auth_state],
        auth_state.session_id == ^profile_id(profile) and auth_state.type == ^type and
          auth_state.key == ^row_key
      )
      |> repo.delete_all()

      :ok
    end
  end

  @impl true
  def clear(%{repo: repo}, profile) do
    AuthState
    |> where([auth_state], auth_state.session_id == ^profile_id(profile))
    |> repo.delete_all()

    :ok
  end

  @impl true
  def list_profiles(%{repo: repo}) do
    profiles =
      AuthState
      |> where([auth_state], auth_state.type == "creds" and auth_state.key == "creds")
      |> distinct(true)
      |> order_by([auth_state], asc: auth_state.session_id)
      |> select([auth_state], auth_state.session_id)
      |> repo.all()

    {:ok, profiles}
  end

  @impl true
  def list_keys(%{repo: repo}, profile, namespace) do
    with {:ok, type} <- namespace_type(namespace) do
      keys =
        AuthState
        |> where(
          [auth_state],
          auth_state.session_id == ^profile_id(profile) and auth_state.type == ^type
        )
        |> order_by([auth_state], asc: auth_state.key)
        |> select([auth_state], auth_state.key)
        |> repo.all()

      {:ok, keys}
    end
  end

  defp row_identity(:creds, :self), do: {:ok, "creds", "creds"}

  defp row_identity(namespace, key) do
    with {:ok, type} <- namespace_type(namespace),
         {:ok, row_key} <- key_string(key) do
      {:ok, type, row_key}
    end
  end

  defp namespace_type(namespace) do
    case Map.fetch(@namespace_types, namespace) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:unsupported_namespace, namespace}}
    end
  end

  defp key_string(key) when is_binary(key), do: {:ok, key}
  defp key_string(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key_string(key), do: {:error, {:unsupported_key, key}}

  defp profile_id(profile) when is_binary(profile), do: profile
  defp profile_id(profile) when is_atom(profile), do: Atom.to_string(profile)
end
