defmodule TelegramVoiceTranscriberAsh.Transcribing.AudioTest do
  @moduledoc "R16, against real ffmpeg — the conversion is a subprocess, not logic."

  use ExUnit.Case, async: true

  alias TelegramVoiceTranscriberAsh.MediaFixtures
  alias TelegramVoiceTranscriberAsh.Transcribing.Audio

  @moduletag :ffmpeg

  setup_all do
    if System.find_executable("ffmpeg") do
      :ok
    else
      raise "ffmpeg is a runtime dependency of the bot and must be installed to run these tests"
    end
  end

  test "the video stream is stripped and the audio survives" do
    assert {:ok, {audio, "audio/aac"}} = Audio.extract_audio(MediaFixtures.video_note())

    assert byte_size(audio) > 0
    # ADTS frames start with a twelve-bit sync word.
    assert <<0xFF, second, _rest::binary>> = audio
    assert Bitwise.band(second, 0xF0) == 0xF0
  end

  test "ffmpeg's complaint is returned rather than raised" do
    assert {:error, message} = Audio.extract_audio("this is not a video")

    assert message =~ "ffmpeg exited with"
    assert message =~ "Invalid data found"
  end

  test "temporary files do not accumulate" do
    before = tmp_entries()

    Audio.extract_audio(MediaFixtures.video_note())
    Audio.extract_audio("not a video")

    assert tmp_entries() == before
  end

  defp tmp_entries do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, "video-") or String.starts_with?(&1, "audio-")))
    |> Enum.sort()
  end
end
