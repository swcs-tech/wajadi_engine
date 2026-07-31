defmodule WajadiEngine.WhatsApp.Storage.Codec do
  @moduledoc """
  Encodes Amarula storage terms into JSONB-friendly maps with explicit fallback.
  """

  @json_encoding "json"
  @fallback_encoding "erlang_term_base64"
  @max_fallback_encoded_bytes 12_000_000
  @max_fallback_decoded_bytes 8_000_000
  @max_atom_bytes 255
  @atom_pattern ~r/^Elixir\.[A-Z][A-Za-z0-9_.]*$|^[a-z_][A-Za-z0-9_?!@]*$/

  @type encoding :: String.t()
  @type json_value :: map()

  @spec encode(term()) :: {encoding(), json_value()}
  def encode(term) do
    case encode_json(term) do
      {:ok, value} -> {@json_encoding, wrap_top_level(value)}
      :unsupported -> fallback_encode(term)
    end
  end

  @spec decode(encoding(), json_value()) :: {:ok, term()} | {:error, term()}
  def decode(@json_encoding, value) when is_map(value), do: decode_json(value)
  def decode(@fallback_encoding, value) when is_map(value), do: fallback_decode(value)
  def decode(encoding, _value), do: {:error, {:unsupported_encoding, encoding}}

  defp encode_json(nil), do: {:ok, nil}
  defp encode_json(value) when is_boolean(value), do: {:ok, value}
  defp encode_json(value) when is_integer(value), do: {:ok, value}
  defp encode_json(value) when is_float(value), do: {:ok, value}

  defp encode_json(value) when is_atom(value) do
    {:ok, %{"__type__" => "atom", "value" => Atom.to_string(value)}}
  end

  defp encode_json(value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      {:ok, %{"__type__" => "binary", "encoding" => "base64", "data" => Base.encode64(value)}}
    end
  end

  defp encode_json(value) when is_list(value) do
    value
    |> encode_many()
    |> case do
      {:ok, items} -> {:ok, %{"__type__" => "list", "items" => items}}
      :unsupported -> :unsupported
    end
  end

  defp encode_json(%{__struct__: module} = value) do
    value
    |> Map.from_struct()
    |> encode_map_entries()
    |> case do
      {:ok, fields} ->
        {:ok,
         %{
           "__type__" => "struct",
           "module" => Atom.to_string(module),
           "fields" => fields
         }}

      :unsupported ->
        :unsupported
    end
  end

  defp encode_json(value) when is_map(value) do
    if plain_json_map?(value) do
      encode_plain_map(value)
    else
      value
      |> encode_map_entries()
      |> case do
        {:ok, entries} -> {:ok, %{"__type__" => "map", "entries" => entries}}
        :unsupported -> :unsupported
      end
    end
  end

  defp encode_json(_value), do: :unsupported

  defp wrap_top_level(value) when is_map(value), do: value
  defp wrap_top_level(value), do: %{"__type__" => "scalar", "value" => value}

  defp encode_plain_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case encode_json(value) do
        {:ok, encoded_value} -> {:cont, {:ok, Map.put(acc, key, encoded_value)}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
  end

  defp encode_map_entries(map) do
    Enum.reduce_while(map, {:ok, []}, fn {key, value}, {:ok, entries} ->
      with {:ok, encoded_key} <- encode_json(key),
           {:ok, encoded_value} <- encode_json(value) do
        {:cont, {:ok, [[encoded_key, encoded_value] | entries]}}
      else
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      :unsupported -> :unsupported
    end
  end

  defp encode_many(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case encode_json(item) do
        {:ok, encoded_item} -> {:cont, {:ok, [encoded_item | acc]}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, encoded_items} -> {:ok, Enum.reverse(encoded_items)}
      :unsupported -> :unsupported
    end
  end

  defp plain_json_map?(map) do
    Enum.all?(map, fn {key, _value} -> is_binary(key) end) and not Map.has_key?(map, "__type__")
  end

  defp decode_json(%{"__type__" => "scalar", "value" => value}), do: decode_json_value(value)

  defp decode_json(value), do: decode_json_value(value)

  defp decode_json_value(nil), do: {:ok, nil}
  defp decode_json_value(value) when is_boolean(value), do: {:ok, value}
  defp decode_json_value(value) when is_integer(value), do: {:ok, value}
  defp decode_json_value(value) when is_float(value), do: {:ok, value}
  defp decode_json_value(value) when is_binary(value), do: {:ok, value}

  defp decode_json_value(%{"__type__" => "binary", "encoding" => "base64", "data" => data})
       when is_binary(data) do
    case Base.decode64(data) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_json_value(%{"__type__" => "atom", "value" => value}) when is_binary(value) do
    existing_atom(value)
  end

  defp decode_json_value(%{"__type__" => "list", "items" => items}) when is_list(items) do
    decode_many(items)
  end

  defp decode_json_value(%{"__type__" => "map", "entries" => entries}) when is_list(entries) do
    decode_entries(entries)
  end

  defp decode_json_value(%{"__type__" => "struct", "module" => module_name, "fields" => fields})
       when is_binary(module_name) and is_list(fields) do
    with {:ok, module} <- existing_atom(module_name),
         {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, field_map} <- decode_entries(fields) do
      {:ok, struct(module, field_map)}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_struct_module, other}}
    end
  end

  defp decode_json_value(%{"__type__" => unknown}), do: {:error, {:unknown_tag, unknown}}

  defp decode_json_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, encoded_value}, {:ok, acc} ->
      case decode_json_value(encoded_value) do
        {:ok, decoded_value} -> {:cont, {:ok, Map.put(acc, key, decoded_value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_json_value(_value), do: {:error, :invalid_json_value}

  defp decode_many(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case decode_json_value(item) do
        {:ok, decoded_item} -> {:cont, {:ok, [decoded_item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded_items} -> {:ok, Enum.reverse(decoded_items)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, acc} ->
        with {:ok, key} <- decode_json_value(encoded_key),
             {:ok, value} <- decode_json_value(encoded_value) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_map_entry}}
    end)
  end

  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> persisted_atom(value)
  end

  defp persisted_atom(value) when byte_size(value) <= @max_atom_bytes do
    if Regex.match?(@atom_pattern, value) do
      {:ok, String.to_atom(value)}
    else
      {:error, {:invalid_atom, value}}
    end
  end

  defp persisted_atom(value), do: {:error, {:atom_too_large, byte_size(value)}}

  defp fallback_encode(value) do
    data = value |> :erlang.term_to_binary() |> Base.encode64()
    {@fallback_encoding, %{"__encoding__" => @fallback_encoding, "data" => data}}
  end

  defp fallback_decode(%{"__encoding__" => @fallback_encoding, "data" => data})
       when is_binary(data) do
    with :ok <- check_encoded_size(data),
         {:ok, binary} <- Base.decode64(data),
         :ok <- check_decoded_size(binary) do
      decode_fallback_binary(binary)
    else
      :error -> {:error, :invalid_base64}
      {:error, _reason} = error -> error
    end
  end

  defp fallback_decode(_value), do: {:error, :invalid_fallback_value}

  defp check_encoded_size(data) do
    if byte_size(data) <= @max_fallback_encoded_bytes do
      :ok
    else
      {:error, :fallback_encoded_too_large}
    end
  end

  defp check_decoded_size(binary) do
    if byte_size(binary) <= @max_fallback_decoded_bytes do
      :ok
    else
      {:error, :fallback_decoded_too_large}
    end
  end

  defp decode_fallback_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> decode_trusted_fallback_binary(binary)
  end

  defp decode_trusted_fallback_binary(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError -> {:error, :invalid_erlang_term}
  end
end
