defmodule TelegramVoiceTranscriberAsh.Bot do
  @moduledoc """
  The Telegram front end. Replaces the source's aiogram routers.

  This slice covers the private-chat path only: a voice message or audio file
  is transcribed, `/start` explains the product and `/stats` reports the
  balance. Group transcription, reply-mentions, forwarding to the operator,
  Stars payments and video notes are later slices.
  """

  use ExGram.Bot,
    name: :telegram_voice_transcriber_ash,
    setup_commands: true

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Messages
  alias TelegramVoiceTranscriberAsh.Bot.Pipeline
  alias TelegramVoiceTranscriberAsh.Metering

  command("start", description: "Что умеет бот")
  command("stats", description: "Сколько минут распознавания осталось")

  @impl ExGram.Handler
  def handle({:command, :start, _message}, context) do
    answer(context, Messages.start())
  end

  def handle({:command, :stats, message}, context) do
    subscriber =
      message.from.id
      |> Identity.hash()
      |> Metering.find_or_register!()

    answer(context, Messages.stats(subscriber))
  end

  def handle({:message, %{chat: %{type: "private"}} = message}, context) do
    case media(message) do
      nil -> context
      media -> run(message, media, context)
    end
  end

  def handle(_message, context), do: context

  defp run(message, media, context) do
    Pipeline.run(message, media)
    context
  end

  defp media(%{voice: %{} = voice}) do
    %{duration: voice.duration, file_id: voice.file_id, mime_type: voice.mime_type}
  end

  defp media(%{audio: %{} = audio}) do
    %{duration: audio.duration, file_id: audio.file_id, mime_type: audio.mime_type}
  end

  defp media(_message), do: nil
end
