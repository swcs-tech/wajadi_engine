defmodule WajadiEngine.WhatsApp.Helpers do
  @moduledoc """
  WhatsApp message formatting, extraction, and send helpers.
  """

  alias Amarula.Address
  alias Amarula.Content.Media
  alias Amarula.Msg

  @individual_suffix "@s.whatsapp.net"

  @type quoted_message :: %{id: String.t(), content: String.t()}

  @spec format_to_jid(String.t()) :: String.t()
  def format_to_jid(number) when is_binary(number) do
    number = String.trim(number)

    if String.contains?(number, "@") do
      number
    else
      number <> @individual_suffix
    end
  end

  @spec address_to_jid(String.t() | Address.t() | nil) :: String.t() | nil
  def address_to_jid(nil), do: nil
  def address_to_jid(jid) when is_binary(jid), do: jid

  def address_to_jid(%Address{} = address) do
    case Address.to_jid(address) do
      {:ok, jid} -> jid
      {:error, :no_jid} -> nil
    end
  end

  @spec extract_message_content(Msg.t()) :: String.t() | nil
  def extract_message_content(%Msg{type: :text, content: text}) when is_binary(text),
    do: present_text(text)

  def extract_message_content(%Msg{type: :media, content: %Media{caption: caption}})
      when is_binary(caption),
      do: present_text(caption)

  def extract_message_content(%Msg{}), do: nil

  @spec message_type(Msg.t()) :: String.t()
  def message_type(%Msg{type: :text}), do: "text"

  def message_type(%Msg{type: :media, content: %Media{kind: kind}}) when is_atom(kind),
    do: Atom.to_string(kind)

  def message_type(%Msg{type: type}) when is_atom(type), do: Atom.to_string(type)

  @spec get_quoted_message(Msg.t()) :: quoted_message() | nil
  def get_quoted_message(%Msg{quoted: %{id: id, message: quoted}}) when is_binary(id) do
    %{id: id, content: extract_quoted_content(quoted)}
  end

  def get_quoted_message(%Msg{}), do: nil

  @spec send_text(Amarula.conn(), String.t(), String.t(), keyword()) :: Amarula.send_result()
  def send_text(conn, jid, text, opts \\ []) when is_binary(jid) and is_binary(text) do
    Amarula.send_text(conn, format_to_jid(jid), text, opts)
  end

  @spec send_media(Amarula.conn(), String.t(), Amarula.media_type(), binary(), keyword()) ::
          Amarula.send_result()
  def send_media(conn, jid, type, data, opts \\ [])
      when is_binary(jid) and is_binary(data) do
    Amarula.send_media(conn, format_to_jid(jid), type, data, opts)
  end

  @spec send_reply(Amarula.conn(), String.t(), String.t(), Msg.t(), keyword()) ::
          Amarula.send_result()
  def send_reply(conn, jid, text, %Msg{} = quoted, opts \\ [])
      when is_binary(jid) and is_binary(text) do
    send_text(conn, jid, text, Keyword.put(opts, :quoted, quoted))
  end

  defp extract_quoted_content(%Msg{} = msg), do: extract_message_content(msg) || ""
  defp extract_quoted_content(_quoted), do: ""

  defp present_text(text) do
    if text == "", do: nil, else: text
  end
end
