defmodule WajadiEngine.WhatsApp.SessionParams do
  @moduledoc """
  Validates external request parameters for WhatsApp session endpoints.
  """

  @max_session_id_length 255

  @type validation_error :: %{path: [String.t()], message: String.t(), code: String.t()}

  @spec validate_create(map()) ::
          {:ok, %{optional(:session_id) => String.t()}} | {:error, [validation_error()]}
  def validate_create(params) when is_map(params) do
    case Map.fetch(params, "session_id") do
      {:ok, session_id} -> validate_session_id(session_id)
      :error -> {:ok, %{}}
    end
  end

  def validate_create(_params) do
    {:error, [%{path: [], message: "Expected object", code: "invalid_type"}]}
  end

  defp validate_session_id(session_id) when is_binary(session_id) do
    cond do
      session_id == "" ->
        {:error,
         [
           %{
             path: ["session_id"],
             message: "String must contain at least 1 character",
             code: "too_small"
           }
         ]}

      String.length(session_id) > @max_session_id_length ->
        {:error,
         [
           %{
             path: ["session_id"],
             message: "String must contain at most 255 characters",
             code: "too_big"
           }
         ]}

      true ->
        {:ok, %{session_id: session_id}}
    end
  end

  defp validate_session_id(_session_id) do
    {:error, [%{path: ["session_id"], message: "Expected string", code: "invalid_type"}]}
  end
end
