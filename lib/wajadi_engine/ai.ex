defmodule WajadiEngine.AI do
  @moduledoc """
  Runtime configuration boundary for AI integrations.
  """

  @default_base_url "http://localhost:20128/v1"
  @default_api_key "dummy-key"
  @default_model "gpt-4o"
  @default_receive_timeout 30_000
  @default_temperature 0.7

  @type config :: %{
          base_url: String.t(),
          endpoint: String.t(),
          api_key: String.t(),
          model: String.t(),
          receive_timeout: pos_integer(),
          temperature: float()
        }

  @spec config() :: config()
  def config do
    configured = Application.get_env(:wajadi_engine, :ai, [])

    base_url =
      configured
      |> Keyword.get(:nine_router_base_url, @default_base_url)
      |> normalize_string(@default_base_url)

    %{
      base_url: base_url,
      endpoint: chat_completions_endpoint(base_url),
      api_key:
        configured
        |> Keyword.get(:nine_router_api_key, @default_api_key)
        |> normalize_string(@default_api_key),
      model:
        configured
        |> Keyword.get(:nine_router_model, @default_model)
        |> normalize_string(@default_model),
      receive_timeout: Keyword.get(configured, :receive_timeout, @default_receive_timeout),
      temperature: Keyword.get(configured, :temperature, @default_temperature)
    }
  end

  defp chat_completions_endpoint(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, "/chat/completions") do
      base_url
    else
      base_url <> "/chat/completions"
    end
  end

  defp normalize_string(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value, default), do: default
end
