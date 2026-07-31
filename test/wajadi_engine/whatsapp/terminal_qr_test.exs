defmodule WajadiEngine.WhatsApp.TerminalQRTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias WajadiEngine.WhatsApp.TerminalQR

  test "prints scannable ANSI QR block" do
    output = capture_io(fn -> TerminalQR.print("session-1", "raw-qr-code") end)

    assert output =~ "WhatsApp QR for session session-1"
    assert output =~ "Scan with WhatsApp mobile"
    assert output =~ "\e[38;2;0;0;0m"
    assert output =~ "\e[48;2;255;255;255m"
  end
end
