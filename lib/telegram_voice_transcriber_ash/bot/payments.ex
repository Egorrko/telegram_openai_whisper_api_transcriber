defmodule TelegramVoiceTranscriberAsh.Bot.Payments do
  @moduledoc """
  Buying recognition minutes with Telegram Stars (scenario 3.6).

  Port of `src/bot/handlers/payment.py`. The pre-checkout query is still
  answered unconditionally — there is nothing to validate, since the amount is
  fixed by the invoice we sent — but the credit itself is now idempotent on the
  Telegram charge ID, so a redelivered update can no longer double-credit.
  """

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Messages
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @min_stars 1
  @max_stars 2500

  @doc "R10: `/payment N` for 1..2500 stars, anything else gets the usage hint."
  def invoice(message, args) do
    case stars(args) do
      {:ok, stars} -> send_invoice(message, stars)
      :error -> reply(message, Messages.payment_usage(), parse_mode: "HTML")
    end

    :ok
  end

  @doc "Telegram requires an answer within 10 seconds, and there is nothing to check."
  def confirm_checkout(query) do
    ExGram.answer_pre_checkout_query(query.id, true, token: token())
    :ok
  end

  @doc "R9: credit the purchase, once per charge ID."
  def credit(message, successful_payment) do
    payment =
      Metering.credit_payment!(
        Identity.hash(message.from.id),
        successful_payment.telegram_payment_charge_id,
        successful_payment.total_amount
      )

    reply(message, Messages.payment_successful(payment.seconds_credited))
    :ok
  end

  def support(message) do
    reply(message, Messages.paysupport())
    :ok
  end

  defp send_invoice(message, stars) do
    minutes = div(stars * Settings.currency_rate_seconds(), 60)

    ExGram.send_invoice(
      message.chat.id,
      "Покупка минут распознавания",
      "Ты покупаешь #{minutes} мин. распознавания",
      "#{stars}_stars",
      "XTR",
      [%ExGram.Model.LabeledPrice{label: "XTR", amount: stars}],
      provider_token: "",
      reply_markup: pay_button(stars),
      token: token()
    )
  end

  defp pay_button(stars) do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [%ExGram.Model.InlineKeyboardButton{text: "Оплатить #{stars} XTR", pay: true}]
      ]
    }
  end

  defp stars(args) do
    case Integer.parse(String.trim(args || "")) do
      {stars, ""} when stars in @min_stars..@max_stars -> {:ok, stars}
      _ -> :error
    end
  end

  defp reply(message, text, opts \\ []) do
    ExGram.send_message(
      message.chat.id,
      text,
      opts ++
        [
          reply_parameters: %ExGram.Model.ReplyParameters{message_id: message.message_id},
          token: token()
        ]
    )
  end

  defp token, do: Settings.telegram_token()
end
