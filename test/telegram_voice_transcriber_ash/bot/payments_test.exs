defmodule TelegramVoiceTranscriberAsh.Bot.PaymentsTest do
  @moduledoc "The Telegram side of scenario 3.6, through the ex_gram test adapter."

  use TelegramVoiceTranscriberAsh.DataCase, async: false
  use ExGram.Test

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Payments
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @telegram_user_id 555_444_333
  @charge_id "charge_abc123"

  setup do
    ExGram.Test.stub(:send_message, fn body ->
      {:ok, %{message_id: 1, chat: %{id: body[:chat_id], type: "private"}, text: body[:text]}}
    end)

    ExGram.Test.stub(:send_invoice, fn body ->
      {:ok, %{message_id: 2, chat: %{id: body[:chat_id], type: "private"}}}
    end)

    ExGram.Test.stub(:answer_pre_checkout_query, true)
    :ok
  end

  defp message do
    %ExGram.Model.Message{
      message_id: 7,
      chat: %ExGram.Model.Chat{id: 111, type: "private"},
      from: %ExGram.Model.User{id: @telegram_user_id}
    }
  end

  defp calls(action) do
    ExGram.Test.get_calls()
    |> Enum.filter(&match?({_, ^action, _}, &1))
    |> Enum.map(fn {_, _, body} -> body end)
  end

  defp subscriber, do: Metering.get_subscriber!(Identity.hash(@telegram_user_id))

  defp successful_payment(amount) do
    %ExGram.Model.SuccessfulPayment{
      currency: "XTR",
      total_amount: amount,
      invoice_payload: "#{amount}_stars",
      telegram_payment_charge_id: @charge_id,
      provider_payment_charge_id: "provider-1"
    }
  end

  describe "/payment N" do
    test "sends a Stars invoice with a single pay button" do
      assert :ok = Payments.invoice(message(), "100")

      assert [invoice] = calls(:send_invoice)
      assert invoice[:currency] == "XTR"
      assert invoice[:provider_token] == ""
      assert invoice[:payload] == "100_stars"
      # ex_gram has already flattened the struct into the request body.
      assert invoice[:prices] == [%{label: "XTR", amount: 100}]

      minutes = div(100 * Settings.currency_rate_seconds(), 60)
      assert invoice[:description] == "Ты покупаешь #{minutes} мин. распознавания"

      assert %{inline_keyboard: [[button]]} = invoice[:reply_markup]
      assert button.pay == true
      assert button.text == "Оплатить 100 XTR"
    end

    test "the range is 1..2500 (R10)" do
      for args <- ["0", "2501", "-5", "abc", "10abc", "", nil] do
        ExGram.Test.clean()

        ExGram.Test.stub(
          :send_message,
          {:ok, %{message_id: 1, chat: %{id: 111, type: "private"}}}
        )

        assert :ok = Payments.invoice(message(), args)
        assert calls(:send_invoice) == []
        assert [%{text: text}] = calls(:send_message)
        assert text =~ "<code>/payment N</code>"
      end
    end

    test "the boundaries themselves are accepted" do
      assert :ok = Payments.invoice(message(), "1")
      assert :ok = Payments.invoice(message(), "2500")

      assert [%{payload: "1_stars"}, %{payload: "2500_stars"}] = calls(:send_invoice)
    end
  end

  test "the pre-checkout query is answered ok" do
    assert :ok = Payments.confirm_checkout(%ExGram.Model.PreCheckoutQuery{id: "pcq-1"})

    assert [%{pre_checkout_query_id: "pcq-1", ok: true}] = calls(:answer_pre_checkout_query)
  end

  describe "successful payment" do
    test "credits the balance and says how many minutes were added" do
      assert :ok = Payments.credit(message(), successful_payment(3))

      seconds = 3 * Settings.currency_rate_seconds()
      assert subscriber().left_purchased_seconds == seconds

      assert [%{text: text}] = calls(:send_message)
      assert text =~ "Платёж успешно проведён"
      assert text =~ "начислено #{div(seconds, 60)} мин"
    end

    test "a redelivered update credits once but still confirms (D2)" do
      assert :ok = Payments.credit(message(), successful_payment(3))
      assert :ok = Payments.credit(message(), successful_payment(3))

      assert subscriber().left_purchased_seconds == 3 * Settings.currency_rate_seconds()
      assert length(calls(:send_message)) == 2
    end
  end

  test "/paysupport names the support contact" do
    Application.put_env(:telegram_voice_transcriber_ash, :support_username, "@someone")
    on_exit(fn -> Application.delete_env(:telegram_voice_transcriber_ash, :support_username) end)

    assert :ok = Payments.support(message())

    assert [%{text: text}] = calls(:send_message)
    assert text =~ "@someone"
  end
end
