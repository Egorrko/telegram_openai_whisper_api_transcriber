defmodule TelegramVoiceTranscriberAsh.Bot do
  @moduledoc """
  The Telegram front end. Replaces the source's aiogram routers.

  Covers the private-chat path: a voice message or audio file is transcribed,
  `/start` explains the product, `/stats` reports the balance, and `/payment N`
  buys minutes with Telegram Stars. Group transcription, reply-mentions,
  forwarding to the operator and video notes are later slices.
  """

  use ExGram.Bot,
    name: :telegram_voice_transcriber_ash,
    setup_commands: true

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Messages
  alias TelegramVoiceTranscriberAsh.Bot.Payments
  alias TelegramVoiceTranscriberAsh.Bot.Pipeline
  alias TelegramVoiceTranscriberAsh.Metering

  command("start", description: "Что умеет бот")
  command("stats", description: "Сколько минут распознавания осталось")
  command("payment", description: "Купить минуты распознавания за звёзды")
  command("paysupport", description: "Проблемы с оплатой")

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

  def handle({:command, :payment, message}, context) do
    Payments.invoice(message, message.text)
    context
  end

  def handle({:command, :paysupport, message}, context) do
    Payments.support(message)
    context
  end

  # Telegram asks for confirmation before charging; ex_gram surfaces it as a
  # bare update because it has no dedicated clause for pre-checkout queries.
  def handle({:update, %{pre_checkout_query: %{} = query}}, context) do
    Payments.confirm_checkout(query)
    context
  end

  def handle({:message, %{successful_payment: %{} = payment} = message}, context) do
    Payments.credit(message, payment)
    context
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
