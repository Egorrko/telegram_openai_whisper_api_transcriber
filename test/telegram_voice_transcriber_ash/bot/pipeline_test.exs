defmodule TelegramVoiceTranscriberAsh.Bot.PipelineTest do
  @moduledoc """
  The whole slice through one seam: a voice message arrives, the transcript is
  edited into the progress message, and the balance moves — or, on failure,
  does not (R8).

  Telegram is the ex_gram test adapter, the file download is a Req plug, and
  the engine is a stub configured through the ordinary `{module, model}`
  engine setting.
  """

  # async: false — Req.default_options/1 and the engine setting are global.
  use TelegramVoiceTranscriberAsh.DataCase, async: false
  use ExGram.Test

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Pipeline
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Metering.TranscriptionLog

  @telegram_user_id 987_654_321
  @audio "OggS-not-really-audio"

  defmodule StubEngine do
    @moduledoc false
    @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

    @impl true
    def transcribe(audio, mime_type, _model) do
      send(:pipeline_test, {:transcribed, audio, mime_type})
      Application.fetch_env!(:telegram_voice_transcriber_ash, :stub_engine_result)
    end
  end

  setup do
    Process.register(self(), :pipeline_test)

    Req.default_options(plug: fn conn -> Plug.Conn.resp(conn, 200, @audio) end)

    Application.put_env(
      :telegram_voice_transcriber_ash,
      :transcription_engine,
      {StubEngine, "stub"}
    )

    on_exit(fn ->
      Req.default_options([])
      Application.delete_env(:telegram_voice_transcriber_ash, :transcription_engine)
      Application.delete_env(:telegram_voice_transcriber_ash, :stub_engine_result)
    end)

    ExGram.Test.stub(:get_file, %{file_id: "file-1", file_path: "voice/file_1.oga"})

    ExGram.Test.stub(:send_message, fn body ->
      {:ok, %{message_id: 555, chat: %{id: body[:chat_id], type: "private"}, text: body[:text]}}
    end)

    ExGram.Test.stub(:edit_message_text, fn body ->
      {:ok, %{message_id: body[:message_id], chat: %{id: body[:chat_id], type: "private"}}}
    end)

    :ok
  end

  defp engine_returns(result),
    do: Application.put_env(:telegram_voice_transcriber_ash, :stub_engine_result, result)

  defp message do
    %ExGram.Model.Message{
      message_id: 42,
      chat: %ExGram.Model.Chat{id: 111, type: "private"},
      from: %ExGram.Model.User{id: @telegram_user_id}
    }
  end

  defp media(duration),
    do: %{duration: duration, file_id: "file-1", mime_type: "audio/ogg"}

  defp subscriber, do: Metering.get_subscriber!(Identity.hash(@telegram_user_id))

  defp logs do
    TranscriptionLog
    |> Ash.read!()
    |> Enum.filter(&(&1.subscriber_id == subscriber().id))
  end

  defp edits do
    ExGram.Test.get_calls()
    |> Enum.filter(&match?({_, :edit_message_text, _}, &1))
    |> Enum.map(fn {_, _, body} -> body end)
  end

  test "a successful transcription is delivered, charged and logged" do
    engine_returns({:ok, Jason.encode!(%{short: "Привет", full: "Привет, мир!"})})

    assert :ok = Pipeline.run(message(), media(60))

    assert_received {:transcribed, @audio, "audio/ogg"}

    charged = subscriber()

    assert charged.left_free_seconds ==
             TelegramVoiceTranscriberAsh.Settings.available_seconds() - 60

    assert [log] = logs()
    assert log.status == :succeeded
    assert log.audio_duration == 60
    assert log.duration_ms >= 0

    assert %{rich_message: rich} = List.last(edits())

    assert %{blocks: [%{type: "blockquote", blocks: [%{text: "Привет, мир!"}]}]} = rich
  end

  test "a self-hosted Bot API server's file is read from disk and removed" do
    engine_returns({:ok, "с диска"})

    path = Path.join(System.tmp_dir!(), "local-#{System.unique_integer([:positive])}.oga")
    File.write!(path, "local audio bytes")
    ExGram.Test.stub(:get_file, %{file_id: "file-1", file_path: path})

    assert :ok = Pipeline.run(message(), media(60))

    assert_received {:transcribed, "local audio bytes", "audio/ogg"}
    refute File.exists?(path)
    assert [%{status: :succeeded}] = logs()
  end

  test "a failed transcription charges nothing but is still recorded (R8)" do
    engine_returns({:error, "движок недоступен"})

    assert :ok = Pipeline.run(message(), media(60))

    assert subscriber().left_free_seconds ==
             TelegramVoiceTranscriberAsh.Settings.available_seconds()

    assert [log] = logs()
    assert log.status == :failed
    assert is_nil(log.duration_ms)

    assert %{text: text} = List.last(edits())
    assert text =~ "Ошибочка (TRANSCRIBE)"
    assert text =~ "движок недоступен"
  end

  test "an exceeded quota stops before any transcription" do
    engine_returns({:ok, "не должно случиться"})

    over_the_limit = TelegramVoiceTranscriberAsh.Settings.available_seconds() + 1

    assert :ok = Pipeline.run(message(), media(over_the_limit))

    refute_received {:transcribed, _, _}
    assert logs() == []

    assert subscriber().left_free_seconds ==
             TelegramVoiceTranscriberAsh.Settings.available_seconds()

    assert [%{text: text}] =
             ExGram.Test.get_calls()
             |> Enum.filter(&match?({_, :send_message, _}, &1))
             |> Enum.map(fn {_, _, body} -> body end)

    assert text =~ "бесплатные минуты закончились"
  end
end
