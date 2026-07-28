defmodule WajadiEngine.WhatsApp.Storage.CodecTest do
  use ExUnit.Case, async: true

  alias WajadiEngine.WhatsApp.Storage.Codec

  describe "encode/1 and decode/2" do
    test "roundtrips maps with string keys as readable JSON" do
      term = %{"jid" => "628123@s.whatsapp.net", "active" => true, "count" => 2}

      assert {"json", json_value} = Codec.encode(term)
      assert json_value["jid"] == "628123@s.whatsapp.net"
      assert {:ok, ^term} = Codec.decode("json", json_value)
    end

    test "roundtrips maps with atom keys without creating new atoms" do
      term = %{creds: %{registration_id: 42}, status: :connected}

      assert {"json", json_value} = Codec.encode(term)
      assert %{"__type__" => "map"} = json_value
      assert {:ok, ^term} = Codec.decode("json", json_value)
    end

    test "roundtrips invalid UTF-8 binaries as tagged base64" do
      term = <<0, 255, 1, 2>>

      assert {"json", %{"__type__" => "binary"} = json_value} = Codec.encode(term)
      assert {:ok, ^term} = Codec.decode("json", json_value)
    end

    test "roundtrips top-level lists and scalars" do
      assert {"json", list_value} = Codec.encode(["a", 1, true])
      assert {:ok, ["a", 1, true]} = Codec.decode("json", list_value)

      assert {"json", scalar_value} = Codec.encode(123)
      assert {:ok, 123} = Codec.decode("json", scalar_value)
    end

    test "roundtrips structs when module and field atoms already exist" do
      term = Amarula.Address.pn("628123")

      assert {"json", %{"__type__" => "struct"} = json_value} = Codec.encode(term)
      assert {:ok, ^term} = Codec.decode("json", json_value)
    end

    test "falls back for unsupported tuple terms" do
      term = {:session_record, 1, %{payload: <<1, 2, 3>>}}

      assert {"erlang_term_base64", %{"__encoding__" => "erlang_term_base64"} = json_value} =
               Codec.encode(term)

      assert {:ok, ^term} = Codec.decode("erlang_term_base64", json_value)
    end

    test "rejects unknown atom tags without creating atoms" do
      value = %{"__type__" => "atom", "value" => "definitely_missing_atom_for_codec_test"}

      assert {:error, {:unknown_atom, "definitely_missing_atom_for_codec_test"}} =
               Codec.decode("json", value)
    end

    test "rejects oversized fallback payloads before decoding" do
      value = %{
        "__encoding__" => "erlang_term_base64",
        "data" => String.duplicate("A", 12_000_001)
      }

      assert {:error, :fallback_encoded_too_large} =
               Codec.decode("erlang_term_base64", value)
    end
  end
end
