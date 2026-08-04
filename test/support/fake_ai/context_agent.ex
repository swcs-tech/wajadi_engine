defmodule WajadiEngine.FakeAI.ContextAgent do
  @moduledoc false

  @receiver __MODULE__.Receiver

  def handle_incoming_message(context, message) do
    if receiver = Process.whereis(@receiver) do
      send(receiver, {:ai_context, context, message})
    end

    {:ok, "AI reply to #{message}"}
  end

  def receiver_name, do: @receiver
end
