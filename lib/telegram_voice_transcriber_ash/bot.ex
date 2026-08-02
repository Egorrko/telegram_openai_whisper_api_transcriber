defmodule TelegramVoiceTranscriberAsh.Bot do
  @moduledoc """
  The Telegram front end. Replaces the source's aiogram routers.

  Voice messages, audio files and video notes are transcribed in private chats,
  in allow-listed groups, and anywhere a reply mentioning the bot points at one.
  Messages from `FORWARD_CHAT_IDS` chats are forwarded to the operator and
  transcribed there. `/start`, `/stats`, `/payment N` and `/paysupport` are the
  commands.

  Clause order is load-bearing, the same way the source's router registration
  order was: payments before media, allow-listed groups before forwarding, and
  the catch-all last.
  """

  use ExGram.Bot,
    name: :telegram_voice_transcriber_ash,
    setup_commands: true

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Messages
  alias TelegramVoiceTranscriberAsh.Bot.Forward
  alias TelegramVoiceTranscriberAsh.Bot.Media
  alias TelegramVoiceTranscriberAsh.Bot.Payments
  alias TelegramVoiceTranscriberAsh.Bot.Pipeline
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @group_types ["group", "supergroup"]

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
    case Media.from(message) do
      nil -> context
      media -> run(message, media, context)
    end
  end

  # R18: the reply-mention path works in *any* group, not only allow-listed
  # ones. That is how the source behaves, and changing it would silently take
  # the feature away from chats that use it.
  def handle({:text, text, %{chat: %{type: type}} = message}, context)
      when type in @group_types do
    with true <- mentions_bot?(text),
         %{} = media <- replied_media(message) do
      Pipeline.run(message, media)
    end

    context
  end

  # R17: allow-listed chats first, exactly like the source's router order — a
  # chat in both lists is transcribed in place rather than forwarded.
  def handle({:message, %{chat: %{type: type, id: chat_id}} = message}, context)
      when type in @group_types do
    cond do
      chat_id in Settings.allowed_chat_ids() -> transcribe_in_group(message)
      chat_id in Settings.forward_chat_ids() -> Forward.run(message)
      true -> :ok
    end

    context
  end

  # Last, so it cannot swallow anything above it — the position the source's
  # catch-all text handler had in its own router order. ex_gram reports an
  # undeclared command with a string name, where a declared one is an atom;
  # both are just text to the user, and the source answered both.
  def handle({:text, _text, %{chat: %{type: "private"}}}, context) do
    answer(context, Messages.unknown_command())
  end

  def handle({:command, command, %{chat: %{type: "private"}}}, context)
      when is_binary(command) do
    answer(context, Messages.unknown_command())
  end

  def handle(_message, context), do: context

  defp run(message, media, context) do
    Pipeline.run(message, media)
    context
  end

  defp mentions_bot?(text) do
    case Settings.bot_username() do
      nil -> false
      username -> String.contains?(text, username)
    end
  end

  # A reply mention transcribes what was replied to — voice or audio only.
  defp replied_media(%{reply_to_message: %{} = replied}) do
    replied |> Media.from() |> Media.of_kind([:voice, :audio])
  end

  defp replied_media(_message), do: nil

  # Allow-listed chats auto-transcribe voice and video notes, but not audio
  # files: the source never did, and a shared music file is not a voice note.
  defp transcribe_in_group(message) do
    case message |> Media.from() |> Media.of_kind([:voice, :video_note]) do
      nil -> :ok
      media -> Pipeline.run(message, media)
    end
  end
end
