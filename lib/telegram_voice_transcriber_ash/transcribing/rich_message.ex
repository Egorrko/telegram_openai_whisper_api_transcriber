defmodule TelegramVoiceTranscriberAsh.Transcribing.RichMessage do
  @moduledoc """
  Renders a transcript as Telegram rich message blocks and delivers it.

  Short transcripts become a block quotation; longer ones a collapsed
  `details` block whose summary is the model's one-line answer (R11-R13).

  ## The Bot API 10.2 gap

  `blocks` on `InputRichMessage` arrived in Bot API 10.2, and ex_gram 0.67
  still models Bot API 10.1 (`html`/`markdown` only). The payload itself is
  plain JSON, so the struct is built with the extra field and ex_gram encodes
  it unchanged — the alternative, hand-rolling both API calls over `Req`,
  would duplicate token handling, the base URL and error mapping for no gain.

  ponytail: `Map.put/3` past the struct's declared fields is the whole hack.
  When ex_gram ships 10.2 support, replace `input_rich_message/1` with a plain
  `%InputRichMessage{blocks: blocks}` and delete this note.
  """

  alias TelegramVoiceTranscriberAsh.Transcribing.ResponseParser

  @plain_text_max_length 200
  @summary_max_length 80
  @max_rich_message_length 32_768
  @default_summary "📝 Транскрипция"

  @type rendered :: {:quotation, String.t()} | {:details, String.t(), [String.t()]}

  @doc """
  Decide how a parsed transcript is laid out.

  Returns `{:quotation, text}` for a short transcript, or
  `{:details, summary, chunks}` where the first chunk replaces the progress
  message and the rest are sent as further replies.
  """
  @spec render(ResponseParser.result()) :: rendered()
  def render(%{full: full} = result) do
    if String.length(full) <= @plain_text_max_length do
      {:quotation, full}
    else
      summary = summary(result)
      {:details, summary, chunk(full, @max_rich_message_length - String.length(summary))}
    end
  end

  @doc "R12: the model's short answer, else the first line, else a generic header."
  @spec summary(ResponseParser.result()) :: String.t()
  def summary(%{short: short, full: full}) do
    with nil <- short,
         "" <- full |> first_line() |> String.slice(0, @summary_max_length) do
      @default_summary
    end
  end

  @doc "The `InputRichMessage` payload for a rendered piece."
  @spec payload(rendered() | {:details, String.t(), String.t()}) :: struct()
  def payload({:quotation, text}) do
    input_rich_message([%{type: "blockquote", blocks: [paragraph(text)]}])
  end

  def payload({:details, summary, chunk}) when is_binary(chunk) do
    input_rich_message([%{type: "details", summary: summary, blocks: [paragraph(chunk)]}])
  end

  @doc """
  Deliver a transcript: edit the progress message into the first (or only)
  piece, then thread any overflow as replies to the original voice message.
  """
  @spec deliver(ResponseParser.result(), keyword()) :: :ok | {:error, term()}
  def deliver(result, opts) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    message_id = Keyword.fetch!(opts, :message_id)
    reply_to = Keyword.fetch!(opts, :reply_to_message_id)
    api_opts = Keyword.take(opts, [:token, :bot])

    case render(result) do
      {:quotation, _} = piece ->
        edit(chat_id, message_id, payload(piece), api_opts)

      {:details, summary, [first | rest]} ->
        with :ok <- edit(chat_id, message_id, payload({:details, summary, first}), api_opts) do
          Enum.reduce_while(rest, :ok, fn chunk, :ok ->
            case send_reply(chat_id, reply_to, payload({:details, summary, chunk}), api_opts) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp edit(chat_id, message_id, payload, api_opts) do
    [chat_id: chat_id, message_id: message_id, rich_message: payload]
    |> Keyword.merge(api_opts)
    |> ExGram.edit_message_text()
    |> normalize()
  end

  defp send_reply(chat_id, reply_to, payload, api_opts) do
    chat_id
    |> ExGram.send_rich_message(
      payload,
      Keyword.merge(
        [reply_parameters: %ExGram.Model.ReplyParameters{message_id: reply_to}],
        api_opts
      )
    )
    |> normalize()
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize(error), do: error

  defp input_rich_message(blocks) do
    Map.put(%ExGram.Model.InputRichMessage{}, :blocks, blocks)
  end

  defp paragraph(text), do: %{type: "paragraph", text: text}

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  defp chunk(text, size) do
    case String.split_at(text, size) do
      {chunk, ""} -> [chunk]
      {chunk, rest} -> [chunk | chunk(rest, size)]
    end
  end
end
