defmodule TelegramVoiceTranscriberAsh.Transcribing.Engines.OpenAI do
  @moduledoc "OpenAI audio transcriptions (`whisper-1`, `gpt-4o-mini-transcribe`). Returns plain text."

  @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

  alias TelegramVoiceTranscriberAsh.Settings

  @url "https://api.openai.com/v1/audio/transcriptions"

  @impl true
  def transcribe(audio, mime_type, model) do
    case Settings.openai_api_key() do
      nil ->
        {:error, "Для OpenAI необходимо установить OPENAI_API_KEY"}

      api_key ->
        Req.post(
          url: @url,
          auth: {:bearer, api_key},
          form_multipart: [
            file: {audio, filename: "audio", content_type: mime_type},
            model: model,
            response_format: "text"
          ],
          receive_timeout: 120_000
        )
        |> handle()
    end
  end

  defp handle({:ok, %{status: 200, body: body}}) when is_binary(body), do: {:ok, body}
  defp handle({:ok, %{status: 200, body: body}}), do: {:ok, to_string(body)}

  defp handle({:ok, %{status: status, body: body}}),
    do: {:error, "OpenAI HTTP #{status}: #{inspect(body)}"}

  defp handle({:error, _} = error), do: error
end
