defmodule WajadiEngine.AI.Agent do
  @moduledoc """
  LangChain-powered WhatsApp AI agent.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Utils.ChainResult
  alias WajadiEngine.AI
  alias WajadiEngine.ProductCatalog
  alias WajadiEngine.WhatsApp.SessionServer
  alias WajadiEngine.WhatsApp.SessionSupervisor

  @default_personality """
  Kamu adalah admin toko Wajadi.
  Balas dalam Bahasa Indonesia dengan gaya ramah, singkat, natural, dan membantu.
  Jangan mengarang produk, harga, stok, promo, ongkir, atau estimasi.
  """

  @reply_policy """
  Kamu sedang membuat auto-reply WhatsApp.
  Aplikasi akan mengirim final reply kamu tepat satu kali ke user.
  Jangan mencoba mengirim pesan sendiri melalui tool.
  Jika user bertanya produk, menu, katalog, product list, stok, harga, atau barang yang dijual, gunakan tool get_product_list.
  Untuk pertanyaan katalog umum seperti "Ada produk apa saja?", panggil tool tanpa query.
  Untuk product spesifik, isi query hanya dengan nama atau deskripsi product yang sudah kamu pahami dari bahasa natural user.
  Jika data tidak tersedia di tool atau prompt, katakan belum tersedia.
  """

  @media_receive_timeout 15_000
  @media_connect_timeout 5_000
  @max_media_bytes 10 * 1024 * 1024

  @type handle_result :: {:ok, String.t()} | {:error, term()}

  @spec system_prompt() :: String.t()
  def system_prompt do
    [personality(), @reply_policy]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec model(keyword()) :: ChatOpenAI.t()
  def model(opts \\ []) do
    config = Keyword.get(opts, :config, AI.config())

    ChatOpenAI.new!(%{
      endpoint: config.endpoint,
      api_key: config.api_key,
      model: Keyword.get(opts, :model, config.model),
      temperature: Keyword.get(opts, :temperature, config.temperature),
      receive_timeout: Keyword.get(opts, :receive_timeout, config.receive_timeout),
      stream: false,
      parallel_tool_calls: false
    })
  end

  @spec tools() :: [Function.t()]
  def tools, do: reply_tools()

  @spec reply_tools() :: [Function.t()]
  def reply_tools do
    [get_product_list_tool()]
  end

  @spec action_tools() :: [Function.t()]
  def action_tools do
    [send_whatsapp_message_tool(), send_whatsapp_image_tool(), reply_whatsapp_message_tool()]
  end

  @spec handle_incoming_message(String.t(), String.t()) :: handle_result()
  def handle_incoming_message(session_id, user_message) do
    handle_incoming_message(session_id, user_message, [])
  end

  @spec handle_incoming_message(String.t(), String.t(), keyword()) :: handle_result()
  def handle_incoming_message(session_id, user_message, opts)
      when is_binary(session_id) and is_binary(user_message) do
    llm = Keyword.get(opts, :model) || model(opts)

    chain =
      LLMChain.new!(%{
        llm: llm,
        custom_context: %{session_id: session_id}
      })
      |> LLMChain.add_tools(Keyword.get(opts, :tools, reply_tools()))
      |> LLMChain.add_messages([
        Message.new_system!(system_prompt()),
        Message.new_user!(user_message)
      ])

    with {:ok, chain} <- run_first_llm_call(chain),
         {:ok, chain} <- run_single_tool_round(chain),
         {:ok, response} <- ChainResult.to_string(chain) do
      {:ok, response}
    else
      {:error, _chain, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      Logger.warning("AI agent failed", reason: exception.__struct__)
      {:error, exception}
  end

  defp run_first_llm_call(%LLMChain{} = chain), do: LLMChain.execute_step(chain)

  defp run_single_tool_round(%LLMChain{needs_response: false} = chain), do: {:ok, chain}

  defp run_single_tool_round(%LLMChain{} = chain) do
    chain
    |> LLMChain.execute_tool_calls()
    |> LLMChain.execute_step()
  end

  defp get_product_list_tool do
    Function.new!(%{
      name: "get_product_list",
      description:
        "Read-only. Returns current product catalog as structured JSON with product IDs, prices, stock quantities, descriptions, and image URLs. Use optional query after interpreting the customer's natural-language request.",
      parameters_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description:
              "Product name or concise product description extracted from the customer's request"
          }
        },
        required: []
      },
      function: fn arguments, _context ->
        products = ProductCatalog.search_products(Map.get(arguments, "query"))
        Logger.debug("Product catalog lookup returned #{length(products)} products")

        {
          :ok,
          ProductCatalog.encode_products(products),
          ProductCatalog.structured_products(products)
        }
      end
    })
  end

  defp send_whatsapp_message_tool do
    Function.new!(%{
      name: "send_whatsapp_message",
      description:
        "Sends a WhatsApp message (text, image, document, video, or audio) to a specific number using a WhatsApp session ID.",
      parameters_schema: %{
        type: "object",
        properties: %{
          sessionId: %{type: "string", description: "The active WhatsApp session ID"},
          to: %{type: "string", description: "Recipient phone number or chat JID"},
          message: %{type: "string", description: "Message text or public media URL"},
          type: %{
            type: "string",
            enum: ["text", "image", "document", "video", "audio"],
            description: "Message type"
          },
          caption: %{type: "string", description: "Caption for image/video/document"}
        },
        required: ["sessionId", "to", "message"]
      },
      function: fn arguments, _context -> {:ok, send_whatsapp_message(arguments)} end
    })
  end

  defp send_whatsapp_image_tool do
    Function.new!(%{
      name: "send_whatsapp_image",
      description:
        "Sends an image to a WhatsApp number using a public URL. Optionally includes a caption.",
      parameters_schema: %{
        type: "object",
        properties: %{
          sessionId: %{type: "string", description: "The active WhatsApp session ID"},
          to: %{type: "string", description: "Recipient phone number or chat JID"},
          imageUrl: %{type: "string", description: "Public URL of the image to send"},
          caption: %{type: "string", description: "Caption for the image"}
        },
        required: ["sessionId", "to", "imageUrl"]
      },
      function: fn arguments, _context -> {:ok, send_whatsapp_image(arguments)} end
    })
  end

  defp reply_whatsapp_message_tool do
    Function.new!(%{
      name: "reply_whatsapp_message",
      description:
        "Replies to a specific WhatsApp message by quoting it when possible. Requires the ID of the message to reply to.",
      parameters_schema: %{
        type: "object",
        properties: %{
          sessionId: %{type: "string", description: "The active WhatsApp session ID"},
          to: %{type: "string", description: "Recipient phone number or chat JID"},
          message: %{type: "string", description: "The reply text to send"},
          quotedId: %{type: "string", description: "ID of the message to reply to"}
        },
        required: ["sessionId", "to", "message", "quotedId"]
      },
      function: fn arguments, _context -> {:ok, reply_whatsapp_message(arguments)} end
    })
  end

  defp send_whatsapp_message(%{"type" => type} = arguments)
       when type in ["image", "document", "video", "audio"] do
    send_media_message(
      arguments,
      type,
      Map.get(arguments, "message"),
      Map.get(arguments, "caption")
    )
  end

  defp send_whatsapp_message(arguments) do
    with {:ok, _session_id, pid} <- active_session(arguments),
         {:ok, to} <- required_string(arguments, "to"),
         {:ok, message} <- required_string(arguments, "message") do
      case SessionServer.send_reply(pid, to, message, save_history: false) do
        {:ok, _msg_id} -> "Successfully sent text message to #{to}"
        {:error, reason} -> "Failed to send message: #{inspect(reason)}"
      end
    else
      {:error, reason} -> format_tool_error(reason)
    end
  end

  defp send_whatsapp_image(arguments) do
    send_media_message(
      arguments,
      "image",
      Map.get(arguments, "imageUrl"),
      Map.get(arguments, "caption")
    )
  end

  defp reply_whatsapp_message(arguments) do
    with {:ok, _session_id, pid} <- active_session(arguments),
         {:ok, to} <- required_string(arguments, "to"),
         {:ok, message} <- required_string(arguments, "message"),
         {:ok, quoted_id} <- required_string(arguments, "quotedId") do
      case SessionServer.send_reply(pid, to, message,
             save_history: false,
             quoted: {quoted_id, to}
           ) do
        {:ok, _msg_id} -> "Successfully replied to message #{quoted_id} in #{to}"
        {:error, reason} -> "Failed to send reply: #{inspect(reason)}"
      end
    else
      {:error, reason} -> format_tool_error(reason)
    end
  end

  defp send_media_message(arguments, type, url, caption) do
    with {:ok, _session_id, pid} <- active_session(arguments),
         {:ok, to} <- required_string(arguments, "to"),
         {:ok, url} <- present_string(url, "media URL"),
         {:ok, media_type} <- media_type(type),
         {:ok, bytes} <- fetch_media(url) do
      opts =
        if is_binary(caption) and caption != "",
          do: [caption: caption, save_history: false],
          else: [save_history: false]

      case SessionServer.send_media(pid, to, media_type, bytes, opts) do
        {:ok, _msg_id} -> "Successfully sent #{type} message to #{to}"
        {:error, reason} -> "Failed to send #{type}: #{inspect(reason)}"
      end
    else
      {:error, reason} -> format_tool_error(reason)
    end
  end

  defp active_session(arguments) do
    with {:ok, session_id} <- required_string(arguments, "sessionId") do
      case SessionSupervisor.whereis(session_id) do
        pid when is_pid(pid) -> {:ok, session_id, pid}
        nil -> {:error, {:inactive_session, session_id}}
      end
    end
  end

  defp required_string(arguments, key), do: present_string(Map.get(arguments, key), key)

  defp present_string(value, _label) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_value}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present_string(_value, label), do: {:error, {:missing_required, label}}

  defp media_type("image"), do: {:ok, :image}
  defp media_type("document"), do: {:ok, :document}
  defp media_type("video"), do: {:ok, :video}
  defp media_type("audio"), do: {:ok, :audio}
  defp media_type(type), do: {:error, {:unsupported_message_type, type}}

  defp fetch_media(url) do
    case Req.get(url,
           retry: false,
           receive_timeout: @media_receive_timeout,
           connect_options: [timeout: @media_connect_timeout],
           into: &collect_media_chunk/2
         ) do
      {:ok, %{status: status, private: private}} when status in 200..299 ->
        if Map.get(private, :wajadi_engine_media_too_large?, false) do
          {:error, :media_too_large}
        else
          private
          |> Map.get(:wajadi_engine_media_chunks, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> then(&{:ok, &1})
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_media_chunk({:data, data}, {request, response}) when is_binary(data) do
    size = Map.get(response.private, :wajadi_engine_media_size, 0) + byte_size(data)

    private =
      response.private
      |> Map.put(:wajadi_engine_media_size, size)
      |> Map.update(:wajadi_engine_media_chunks, [data], &[data | &1])

    response = %{response | private: private}

    if size > @max_media_bytes do
      {:halt, {request, put_in(response.private[:wajadi_engine_media_too_large?], true)}}
    else
      {:cont, {request, response}}
    end
  end

  defp format_tool_error({:inactive_session, session_id}),
    do: "Failed: Session \"#{session_id}\" is not active or connected."

  defp format_tool_error({:missing_required, field}), do: "Failed: Missing required #{field}."
  defp format_tool_error(:empty_value), do: "Failed: Required value is empty."
  defp format_tool_error(reason), do: "Failed: #{inspect(reason)}"

  defp personality do
    :wajadi_engine
    |> Application.get_env(:ai_agent, [])
    |> Keyword.get(:personality, @default_personality)
  end
end
