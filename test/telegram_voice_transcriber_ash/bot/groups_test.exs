defmodule TelegramVoiceTranscriberAsh.Bot.GroupsTest do
  @moduledoc """
  Scenarios 3.4 and 3.5: which group messages are transcribed, which are
  forwarded to the operator, and who pays for them.
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: false
  use ExGram.Test

  alias TelegramVoiceTranscriberAsh.Bot
  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @speaker_id 135_792_468
  @admin_id 999_000_111
  @allowed_chat -1_000_000_000_042
  @forward_chat -1_000_000_000_043
  @other_chat -1_000_000_000_044

  defmodule StubEngine do
    @moduledoc false
    @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

    @impl true
    def transcribe(_audio, _mime_type, _model), do: {:ok, "Расшифровка"}
  end

  setup context do
    start_supervised!(ExGram)
    {bot_name, _} = ExGram.Test.start_bot(context, Bot, setup_commands: false, get_me: false)

    Req.default_options(plug: fn conn -> Plug.Conn.resp(conn, 200, "audio") end)

    put_env(:transcription_engine, {StubEngine, "s"})
    put_env(:bot_username, "@transcriber_bot")
    put_env(:allowed_chat_ids, [@allowed_chat])
    put_env(:forward_chat_ids, [@forward_chat])
    put_env(:admin_id, @admin_id)

    on_exit(fn -> Req.default_options([]) end)

    ExGram.Test.stub(:get_file, %{file_id: "f", file_path: "voice/f.oga"})

    ExGram.Test.stub(:send_message, fn body ->
      {:ok, %{message_id: 9, chat: %{id: body[:chat_id], type: "private"}, text: body[:text]}}
    end)

    ExGram.Test.stub(:edit_message_text, fn body ->
      {:ok, %{message_id: body[:message_id], chat: %{id: body[:chat_id], type: "private"}}}
    end)

    ExGram.Test.stub(:forward_message, fn body ->
      {:ok, %{message_id: 4242, chat: %{id: body[:chat_id], type: "private"}}}
    end)

    {:ok, bot_name: bot_name}
  end

  defp put_env(key, value) do
    Application.put_env(:telegram_voice_transcriber_ash, key, value)
    on_exit(fn -> Application.delete_env(:telegram_voice_transcriber_ash, key) end)
  end

  defp voice(duration \\ 8),
    do: %ExGram.Model.Voice{file_id: "f", duration: duration, mime_type: "audio/ogg"}

  defp group_message(chat_id, fields) do
    struct!(
      ExGram.Model.Message,
      Keyword.merge(
        [
          message_id: System.unique_integer([:positive]),
          chat: %ExGram.Model.Chat{id: chat_id, type: "supergroup", title: "Команда"},
          from: %ExGram.Model.User{id: @speaker_id, first_name: "Егор", last_name: "Тестов"}
        ],
        fields
      )
    )
  end

  defp push(bot, message) do
    ExGram.Test.push_update(
      bot,
      %ExGram.Model.Update{update_id: System.unique_integer([:positive]), message: message}
    )
  end

  defp calls(action) do
    ExGram.Test.get_calls()
    |> Enum.filter(&match?({_, ^action, _}, &1))
    |> Enum.map(fn {_, _, body} -> body end)
  end

  defp speaker, do: Metering.get_subscriber!(Identity.hash(@speaker_id))
  defp charged?, do: speaker().left_free_seconds < Settings.available_seconds()

  describe "allow-listed chats (R17)" do
    test "a voice message is transcribed automatically", %{bot_name: bot} do
      push(bot, group_message(@allowed_chat, voice: voice()))

      assert %{rich_message: _} = List.last(calls(:edit_message_text))
      assert charged?()
    end

    test "an audio file is not — only voice notes and video notes are", %{bot_name: bot} do
      audio = %ExGram.Model.Audio{file_id: "f", duration: 8, mime_type: "audio/mpeg"}

      push(bot, group_message(@allowed_chat, audio: audio))

      assert calls(:edit_message_text) == []
    end

    test "a voice message in any other group is ignored", %{bot_name: bot} do
      push(bot, group_message(@other_chat, voice: voice()))

      assert calls(:send_message) == []
      assert calls(:forward_message) == []
    end
  end

  describe "reply mentions (R18)" do
    test "work in a group that is on no list at all", %{bot_name: bot} do
      replied = group_message(@other_chat, voice: voice())

      push(
        bot,
        group_message(@other_chat, text: "@transcriber_bot расшифруй", reply_to_message: replied)
      )

      assert %{rich_message: _} = List.last(calls(:edit_message_text))
      assert charged?()
    end

    test "a reply without the bot's username does nothing", %{bot_name: bot} do
      replied = group_message(@other_chat, voice: voice())

      push(bot, group_message(@other_chat, text: "ага", reply_to_message: replied))

      assert calls(:send_message) == []
    end

    test "a mention replying to something that is not media does nothing", %{bot_name: bot} do
      replied = group_message(@other_chat, text: "просто текст")

      push(
        bot,
        group_message(@other_chat, text: "@transcriber_bot ну?", reply_to_message: replied)
      )

      assert calls(:send_message) == []
    end
  end

  describe "forwarding to the operator (3.5)" do
    test "forwards, annotates, and charges the original sender", %{bot_name: bot} do
      push(bot, group_message(@forward_chat, voice: voice()))

      assert [forward] = calls(:forward_message)
      assert forward[:chat_id] == @admin_id
      assert forward[:from_chat_id] == @forward_chat

      assert [%{text: info} | _] = calls(:send_message)
      assert info =~ "From: Команда"
      assert info =~ "User: Егор Тестов"

      # The transcript lands next to the operator's copy...
      assert [%{chat_id: @admin_id} | _] = calls(:edit_message_text)
      # ...while the speaker pays for it.
      assert charged?()
    end

    test "does nothing when no operator is configured", %{bot_name: bot} do
      Application.put_env(:telegram_voice_transcriber_ash, :admin_id, nil)

      push(bot, group_message(@forward_chat, voice: voice()))

      assert calls(:forward_message) == []
    end

    test "a forwarding failure stays out of the source chat", %{bot_name: bot} do
      ExGram.Test.stub_error(:forward_message, %ExGram.Error{code: 403, message: "blocked"})

      push(bot, group_message(@forward_chat, voice: voice()))

      assert calls(:send_message) == []
      # Nothing reached the ledger either: the failure happened before it.
      assert {:ok, nil} =
               Metering.get_subscriber(Identity.hash(@speaker_id), not_found_error?: false)
    end
  end
end
