defmodule WajadiEngine.WhatsApp.Storage.PostgresTest do
  use WajadiEngine.DataCase

  alias WajadiEngine.Repo
  alias WajadiEngine.WhatsApp.AuthState
  alias WajadiEngine.WhatsApp.Storage.Postgres

  setup do
    %{state: Postgres.new([]), profile: "session-#{System.unique_integer([:positive])}"}
  end

  describe "Amarula.Storage callbacks" do
    test "put/get stores creds under TS-compatible row identity", %{
      state: state,
      profile: profile
    } do
      creds = %{noise_key: <<0, 255>>, status: :paired}

      assert :ok = Postgres.put(state, profile, :creds, :self, creds)
      assert {:ok, ^creds} = Postgres.get(state, profile, :creds, :self)

      assert %AuthState{type: "creds", key: "creds", encoding: "json", value: value} =
               Repo.get_by(AuthState, session_id: profile, type: "creds", key: "creds")

      assert is_map(value)
    end

    test "put uses atomic upsert", %{state: state, profile: profile} do
      assert :ok = Postgres.put(state, profile, :session, "user-1", %{version: 1})
      assert :ok = Postgres.put(state, profile, :session, "user-1", %{version: 2})

      assert {:ok, %{version: 2}} = Postgres.get(state, profile, :session, "user-1")
      assert Repo.aggregate(AuthState, :count) == 1
    end

    test "delete removes one key and missing rows are misses", %{state: state, profile: profile} do
      assert :ok = Postgres.put(state, profile, :sender_key, "group-1", %{record: "value"})
      assert {:ok, %{record: "value"}} = Postgres.get(state, profile, :sender_key, "group-1")

      assert :ok = Postgres.delete(state, profile, :sender_key, "group-1")
      assert :error = Postgres.get(state, profile, :sender_key, "group-1")
      assert :ok = Postgres.delete(state, profile, :sender_key, "group-1")
    end

    test "clear removes all rows for one profile only", %{state: state, profile: profile} do
      other_profile = profile <> "-other"

      assert :ok = Postgres.put(state, profile, :creds, :self, %{id: profile})
      assert :ok = Postgres.put(state, profile, :session, "user-1", %{id: 1})
      assert :ok = Postgres.put(state, other_profile, :creds, :self, %{id: other_profile})

      assert :ok = Postgres.clear(state, profile)

      assert :error = Postgres.get(state, profile, :creds, :self)
      assert :error = Postgres.get(state, profile, :session, "user-1")
      assert {:ok, %{id: ^other_profile}} = Postgres.get(state, other_profile, :creds, :self)
    end

    test "list_profiles returns profiles with creds rows only", %{state: state, profile: profile} do
      other_profile = profile <> "-other"

      assert :ok = Postgres.put(state, profile, :creds, :self, %{id: profile})
      assert :ok = Postgres.put(state, other_profile, :session, "user-1", %{id: 1})

      assert {:ok, profiles} = Postgres.list_profiles(state)
      assert profile in profiles
      refute other_profile in profiles
    end

    test "list_keys returns namespace keys", %{state: state, profile: profile} do
      assert :ok = Postgres.put(state, profile, :session, "user-2", %{id: 2})
      assert :ok = Postgres.put(state, profile, :session, "user-1", %{id: 1})
      assert :ok = Postgres.put(state, profile, :sender_key, "group-1", %{id: 3})

      assert {:ok, ["user-1", "user-2"]} = Postgres.list_keys(state, profile, :session)
    end

    test "fallback rows are discoverable by encoding", %{state: state, profile: profile} do
      term = {:unsupported, %{payload: <<1, 2, 3>>}}

      assert :ok = Postgres.put(state, profile, :app_state_version, "critical_block", term)

      assert %AuthState{encoding: "erlang_term_base64"} =
               Repo.get_by(AuthState,
                 session_id: profile,
                 type: "app-state-version",
                 key: "critical_block"
               )

      assert {:ok, ^term} = Postgres.get(state, profile, :app_state_version, "critical_block")
    end

    test "Amarula.new builds with Postgres storage", %{profile: profile} do
      assert %Amarula.Conn{profile: ^profile} =
               Amarula.new(%{profile: profile, storage: {Postgres, []}})
    end
  end
end
