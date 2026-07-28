defmodule WajadiEngine.FakeAI.ErrorAgent do
  @moduledoc false

  def handle_incoming_message(_session_id, _message), do: {:error, :ai_failed}
end
