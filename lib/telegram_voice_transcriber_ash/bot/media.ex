defmodule TelegramVoiceTranscriberAsh.Bot.Media do
  @moduledoc """
  The three kinds of Telegram media this bot transcribes, reduced to what the
  pipeline needs. Which kinds are accepted differs per entry point, so callers
  narrow the result with `of_kind/2`.
  """

  @type t :: %{
          kind: :voice | :audio | :video_note,
          duration: non_neg_integer(),
          file_id: String.t(),
          mime_type: String.t()
        }

  @spec from(map()) :: t() | nil
  def from(%{voice: %{} = voice}) do
    %{kind: :voice, duration: voice.duration, file_id: voice.file_id, mime_type: voice.mime_type}
  end

  def from(%{audio: %{} = audio}) do
    %{kind: :audio, duration: audio.duration, file_id: audio.file_id, mime_type: audio.mime_type}
  end

  # Telegram reports no mime type for video notes; the source assumed mp4, and
  # ffmpeg replaces it with audio/aac before any engine sees it.
  def from(%{video_note: %{} = note}) do
    %{kind: :video_note, duration: note.duration, file_id: note.file_id, mime_type: "video/mp4"}
  end

  def from(_message), do: nil

  @spec of_kind(t() | nil, [atom()]) :: t() | nil
  def of_kind(%{kind: kind} = media, kinds) do
    if kind in kinds, do: media
  end

  def of_kind(_media, _kinds), do: nil
end
