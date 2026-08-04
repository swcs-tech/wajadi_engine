defmodule WajadiEngine.FakeAI.SuccessAgent do
  @moduledoc false

  def handle_incoming_message(%{account_id: _, store_id: _, session_id: _}, message),
    do: {:ok, "AI reply to #{message}"}
end
