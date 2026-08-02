defmodule TelegramVoiceTranscriberAsh.MediaFixtures do
  @moduledoc "Real media for the tests that exercise the ffmpeg step."

  @doc "One second of a Telegram-video-note-shaped mp4, with an audible tone."
  def video_note do
    path = Path.join(System.tmp_dir!(), "fixture-#{System.unique_integer([:positive])}.mp4")

    {_output, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -f lavfi -i testsrc=size=240x240:rate=15:duration=1
           -f lavfi -i sine=frequency=440:duration=1
           -c:v libx264 -c:a aac -shortest) ++ [path],
        stderr_to_stdout: true
      )

    video = File.read!(path)
    File.rm(path)
    video
  end
end
