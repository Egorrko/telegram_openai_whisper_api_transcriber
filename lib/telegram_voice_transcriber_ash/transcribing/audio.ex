defmodule TelegramVoiceTranscriberAsh.Transcribing.Audio do
  @moduledoc """
  Strips the video stream off a Telegram video note, leaving the audio the
  engines can read (R16).

  Port of `convert_video_to_audio` in `src/bot/services/file_processor.py`. The
  audio stream is copied, not re-encoded, so this costs almost nothing.
  """

  @mime_type "audio/aac"

  @doc "Returns `{:ok, {audio, mime_type}}` or `{:error, ffmpeg's own complaint}`."
  @spec extract_audio(binary()) :: {:ok, {binary(), String.t()}} | {:error, String.t()}
  def extract_audio(video) do
    input = temp_path("video")
    output = temp_path("audio")

    try do
      File.write!(input, video)

      case System.cmd("ffmpeg", args(input, output), stderr_to_stdout: true) do
        {_output, 0} -> {:ok, {File.read!(output), @mime_type}}
        {output, status} -> {:error, "ffmpeg exited with #{status}:\n#{output}"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    after
      File.rm(input)
      File.rm(output)
    end
  end

  defp args(input, output) do
    ["-y", "-i", input, "-vn", "-c:a", "copy", "-f", "adts", output]
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
    )
  end
end
