defmodule WajadiEngine.FakeAI.ErrorAgent do
  @moduledoc false

  def handle_incoming_message(%{account_id: _, store_id: _, session_id: _}, _message),
    do: {:error, :ai_failed}
end
