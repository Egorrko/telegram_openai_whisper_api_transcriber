defmodule TelegramVoiceTranscriberAsh.Transcribing.Engines.ElevenLabs do
  @moduledoc "ElevenLabs speech-to-text (Scribe v1/v2). Returns plain text."

  @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

  alias TelegramVoiceTranscriberAsh.Settings

  @url "https://api.elevenlabs.io/v1/speech-to-text"

  @impl true
  def transcribe(audio, mime_type, model) do
    case Settings.elevenlabs_api_key() do
      nil ->
        {:error, "Для ElevenLabs необходимо установить ELEVENLABS_API_KEY"}

      api_key ->
        Req.post(
          url: @url,
          headers: [{"xi-api-key", api_key}],
          form_multipart: [
            file: {audio, filename: "audio", content_type: mime_type},
            model_id: model
          ],
          receive_timeout: 120_000
        )
        |> handle()
    end
  end

  # The source falls back to "..." rather than failing on an empty result.
  defp handle({:ok, %{status: 200, body: %{"text" => text}}}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp handle({:ok, %{status: 200}}), do: {:ok, "..."}

  defp handle({:ok, %{status: status, body: body}}),
    do: {:error, "ElevenLabs HTTP #{status}: #{inspect(body)}"}

  defp handle({:error, _} = error), do: error
end
