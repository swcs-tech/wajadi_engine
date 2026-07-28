defmodule WajadiEngine.WhatsApp.HelpersTest do
  use ExUnit.Case, async: true

  alias Amarula.Address
  alias Amarula.Content.Media
  alias Amarula.Msg
  alias Amarula.Protocol.Proto
  alias WajadiEngine.WhatsApp.Helpers

  describe "format_to_jid/1" do
    test "adds individual suffix to plain phone numbers" do
      assert Helpers.format_to_jid("628123") == "628123@s.whatsapp.net"
    end

    test "keeps existing JID unchanged" do
      assert Helpers.format_to_jid("120363@g.us") == "120363@g.us"
    end
  end

  describe "extract_message_content/1" do
    test "extracts text message content" do
      assert Helpers.extract_message_content(text_msg("hello")) == "hello"
    end

    test "extracts media caption content" do
      msg = %Msg{
        channel: Address.pn("628123"),
        from: Address.pn("628123"),
        to: Address.pn("628999"),
        type: :media,
        content: %Media{kind: :image, caption: "caption"},
        raw: %Proto.Message{}
      }

      assert Helpers.extract_message_content(msg) == "caption"
      assert Helpers.message_type(msg) == "image"
    end

    test "returns nil for empty text and non-text content" do
      assert Helpers.extract_message_content(text_msg("")) == nil

      msg = %Msg{
        channel: Address.pn("628123"),
        type: :other,
        content: nil,
        raw: %Proto.Message{}
      }

      assert Helpers.extract_message_content(msg) == nil
    end
  end

  describe "get_quoted_message/1" do
    test "extracts quoted message id and content" do
      msg = %Msg{
        channel: Address.pn("628123"),
        type: :text,
        content: "reply",
        quoted: %{id: "quoted-1", message: text_msg("quoted text")},
        raw: %Proto.Message{}
      }

      assert Helpers.get_quoted_message(msg) == %{id: "quoted-1", content: "quoted text"}
    end
  end

  defp text_msg(text) do
    %Msg{
      channel: Address.pn("628123"),
      from: Address.pn("628123"),
      to: Address.pn("628999"),
      type: :text,
      content: text,
      raw: %Proto.Message{}
    }
  end
end
