defmodule TelegramVoiceTranscriberAsh.BotTest do
  @moduledoc """
  Routing: real updates through the real ex_gram dispatcher, so command names,
  command arguments and the payment update shapes are checked rather than
  assumed.
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: false
  use ExGram.Test

  alias TelegramVoiceTranscriberAsh.Bot
  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.MediaFixtures
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @telegram_user_id 246_813_579

  defmodule StubEngine do
    @moduledoc false
    @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

    @impl true
    def transcribe(_audio, _mime_type, _model), do: {:ok, "Расшифровка"}
  end

  setup context do
    # The application does not start ExGram in :test, so the bot registry has
    # to exist before a bot can register itself in it.
    start_supervised!(ExGram)

    {bot_name, _} =
      ExGram.Test.start_bot(context, Bot, setup_commands: false, get_me: false)

    Req.default_options(plug: fn conn -> Plug.Conn.resp(conn, 200, "audio") end)
    Application.put_env(:telegram_voice_transcriber_ash, :transcription_engine, {StubEngine, "s"})

    on_exit(fn ->
      Req.default_options([])
      Application.delete_env(:telegram_voice_transcriber_ash, :transcription_engine)
    end)

    ExGram.Test.stub(:get_file, %{file_id: "f", file_path: "voice/f.oga"})
    ExGram.Test.stub(:send_invoice, %{message_id: 2, chat: %{id: 111, type: "private"}})
    ExGram.Test.stub(:answer_pre_checkout_query, true)

    ExGram.Test.stub(:send_message, fn body ->
      {:ok, %{message_id: 9, chat: %{id: body[:chat_id], type: "private"}, text: body[:text]}}
    end)

    ExGram.Test.stub(:edit_message_text, fn body ->
      {:ok, %{message_id: body[:message_id], chat: %{id: body[:chat_id], type: "private"}}}
    end)

    {:ok, bot_name: bot_name}
  end

  defp update(fields) do
    struct!(
      ExGram.Model.Update,
      Keyword.put_new_lazy(fields, :update_id, fn -> System.unique_integer([:positive]) end)
    )
  end

  defp message(fields) do
    struct!(
      ExGram.Model.Message,
      Keyword.merge(
        [
          message_id: System.unique_integer([:positive]),
          chat: %ExGram.Model.Chat{id: 111, type: "private"},
          from: %ExGram.Model.User{id: @telegram_user_id}
        ],
        fields
      )
    )
  end

  defp calls(action) do
    ExGram.Test.get_calls()
    |> Enum.filter(&match?({_, ^action, _}, &1))
    |> Enum.map(fn {_, _, body} -> body end)
  end

  defp texts, do: Enum.map(calls(:send_message), & &1[:text])

  test "/start explains the product", %{bot_name: bot} do
    ExGram.Test.push_update(bot, update(message: message(text: "/start")))

    assert [text] = texts()
    assert text =~ "Ничего не записываю и не храню"
  end

  test "/stats reports the balance and registers the account", %{bot_name: bot} do
    ExGram.Test.push_update(bot, update(message: message(text: "/stats")))

    assert [text] = texts()
    assert text =~ "Бесплатные: #{div(Settings.available_seconds(), 60)}"
    assert Metering.get_subscriber!(Identity.hash(@telegram_user_id))
  end

  test "plain text in a private chat explains that the bot is not the sender", %{bot_name: bot} do
    ExGram.Test.push_update(bot, update(message: message(text: "спасибо!")))

    assert [text] = texts()
    assert text =~ "Ответ не будет доставлен собеседнику"
  end

  test "an unknown command is answered the same way", %{bot_name: bot} do
    ExGram.Test.push_update(bot, update(message: message(text: "/nope")))

    assert [text] = texts()
    assert text =~ "Полезные команды"
  end

  test "/payment carries its argument through to the invoice", %{bot_name: bot} do
    ExGram.Test.push_update(bot, update(message: message(text: "/payment 42")))

    assert [%{payload: "42_stars"}] = calls(:send_invoice)
  end

  test "a pre-checkout query is confirmed", %{bot_name: bot} do
    query = %ExGram.Model.PreCheckoutQuery{
      id: "pcq-9",
      currency: "XTR",
      total_amount: 7,
      invoice_payload: "7_stars",
      from: %ExGram.Model.User{id: @telegram_user_id}
    }

    ExGram.Test.push_update(bot, update(pre_checkout_query: query))

    assert [%{pre_checkout_query_id: "pcq-9", ok: true}] = calls(:answer_pre_checkout_query)
  end

  test "a successful payment credits the account", %{bot_name: bot} do
    payment = %ExGram.Model.SuccessfulPayment{
      currency: "XTR",
      total_amount: 7,
      invoice_payload: "7_stars",
      telegram_payment_charge_id: "charge-routing"
    }

    ExGram.Test.push_update(bot, update(message: message(successful_payment: payment)))

    subscriber = Metering.get_subscriber!(Identity.hash(@telegram_user_id))
    assert subscriber.left_purchased_seconds == 7 * Settings.currency_rate_seconds()
  end

  test "a video note is converted before it reaches the engine", %{bot_name: bot} do
    video = MediaFixtures.video_note()
    Req.default_options(plug: fn conn -> Plug.Conn.resp(conn, 200, video) end)

    note = %ExGram.Model.VideoNote{file_id: "f", duration: 5, length: 240}

    ExGram.Test.push_update(bot, update(message: message(video_note: note)))

    assert Enum.any?(calls(:edit_message_text), &(&1[:text] == "Достаю звук из видео..."))
    assert %{rich_message: %{blocks: [_ | _]}} = List.last(calls(:edit_message_text))

    subscriber = Metering.get_subscriber!(Identity.hash(@telegram_user_id))
    assert subscriber.left_free_seconds == Settings.available_seconds() - 5
  end

  test "a voice message in a private chat is transcribed", %{bot_name: bot} do
    voice = %ExGram.Model.Voice{file_id: "f", duration: 12, mime_type: "audio/ogg"}

    ExGram.Test.push_update(bot, update(message: message(voice: voice)))

    assert %{rich_message: %{blocks: [%{type: "blockquote"} | _]}} =
             List.last(calls(:edit_message_text))

    subscriber = Metering.get_subscriber!(Identity.hash(@telegram_user_id))
    assert subscriber.left_free_seconds == Settings.available_seconds() - 12
  end
end
