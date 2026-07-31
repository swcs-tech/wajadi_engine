defmodule WajadiEngine.WhatsApp.TerminalQR do
  @moduledoc """
  Prints WhatsApp login QR codes as ANSI blocks for local dev sessions.
  """

  @black {0, 0, 0}
  @white {255, 255, 255}
  @quiet_zone 4
  @horizontal_scale {4, 3}

  @spec maybe_print(String.t(), String.t()) :: :ok
  def maybe_print(session_id, qr) when is_binary(session_id) and is_binary(qr) do
    if Application.get_env(:wajadi_engine, :whatsapp_print_qr, false) do
      print(session_id, qr)
    end

    :ok
  end

  @spec print(String.t(), String.t()) :: :ok
  def print(session_id, qr) when is_binary(session_id) and is_binary(qr) do
    case QRCode.create(qr, :medium) do
      {:ok, %{matrix: matrix}} ->
        IO.puts("\nWhatsApp QR for session #{session_id}")
        IO.puts("Scan with WhatsApp mobile. Set PRINT_WA_QR=false to disable.\n")

        matrix
        |> scale_horizontally(@horizontal_scale)
        |> add_quiet_zone(@quiet_zone)
        |> Enum.chunk_every(2, 2, [blank_row(matrix)])
        |> Enum.each(&IO.puts(render_row_pair(&1)))

        IO.puts("")

      {:error, reason} ->
        IO.puts("Failed to render WhatsApp QR for session #{session_id}: #{inspect(reason)}")
    end

    :ok
  end

  defp scale_horizontally(matrix, {numerator, denominator}) do
    Enum.map(matrix, fn row ->
      row
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {cell, index} ->
        copies = div(index * numerator, denominator) - div((index - 1) * numerator, denominator)
        List.duplicate(cell, copies)
      end)
    end)
  end

  defp add_quiet_zone(matrix, size) do
    width = matrix_width(matrix)
    blank_row = List.duplicate(0, width + size * 2)
    padding = List.duplicate(blank_row, size)

    rows =
      Enum.map(matrix, fn row ->
        List.duplicate(0, size) ++ row ++ List.duplicate(0, size)
      end)

    padding ++ rows ++ padding
  end

  defp blank_row(matrix) do
    width = matrix |> scale_horizontally(@horizontal_scale) |> matrix_width()
    List.duplicate(0, width + @quiet_zone * 2)
  end

  defp matrix_width(matrix), do: matrix |> List.first([]) |> length()

  defp render_row_pair([upper_row, lower_row]) do
    upper_row
    |> Enum.zip(lower_row)
    |> Enum.map_join(fn {upper, lower} -> half_block(color(upper), color(lower)) end)
  end

  defp color(1), do: @black
  defp color(_other), do: @white

  defp half_block({fr, fg, fb}, {br, bg, bb}) do
    "\e[38;2;#{fr};#{fg};#{fb}m\e[48;2;#{br};#{bg};#{bb}m▀\e[0m"
  end
end
