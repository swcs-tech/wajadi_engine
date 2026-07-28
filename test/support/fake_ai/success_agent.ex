defmodule WajadiEngine.FakeAI.SuccessAgent do
  @moduledoc false

  def handle_incoming_message(_session_id, message), do: {:ok, "AI reply to #{message}"}
end
