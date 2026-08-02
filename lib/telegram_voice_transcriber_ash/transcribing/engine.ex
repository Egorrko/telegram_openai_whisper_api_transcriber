defmodule TelegramVoiceTranscriberAsh.Transcribing.Engine do
  @moduledoc """
  Speech-to-text providers, and the retry policy around them (R15).

  Engines are resolved lazily by name: unlike the source, which instantiated
  all nine clients on import and crashed at startup on a missing key for an
  engine it never used, nothing here touches a provider until it is called.
  """

  alias TelegramVoiceTranscriberAsh.Settings

  @callback transcribe(audio :: binary(), mime_type :: String.t(), model :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  alias TelegramVoiceTranscriberAsh.Transcribing.Engines

  @engines %{
    "openai-whisper" => {Engines.OpenAI, "whisper-1"},
    "openai-gpt-4o-mini-transcribe" => {Engines.OpenAI, "gpt-4o-mini-transcribe"},
    "elevenlabs-scribe_v1" => {Engines.ElevenLabs, "scribe_v1"},
    "elevenlabs-scribe_v2" => {Engines.ElevenLabs, "scribe_v2"},
    "gemini-2.5-flash" => {Engines.Gemini, "gemini-2.5-flash"},
    "gemini-3-flash-preview" => {Engines.Gemini, "gemini-3-flash-preview"},
    "gemini-2.5-flash-lite" => {Engines.Gemini, "gemini-2.5-flash-lite"},
    "gemini-3.1-flash-lite" => {Engines.Gemini, "gemini-3.1-flash-lite"},
    "gemini-3.5-flash-lite" => {Engines.Gemini, "gemini-3.5-flash-lite"}
  }

  @doc "Every engine name the `TRANSCRIPTION_ENGINE` setting accepts."
  def names, do: Map.keys(@engines)

  @doc """
  Transcribe `audio`, retrying the primary engine and then trying the fallback
  once, exactly like the source pipeline.

  Options:

    * `:engine` / `:fallback` — an engine name or a `{module, model}` pair,
      defaulting to the configured ones
    * `:on_retry` — `fun.(attempt, max_attempts, delay_ms)`, called before each
      backoff so the caller can update the progress message
    * `:sleep` — override the sleep function (tests)
  """
  @spec transcribe(binary(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def transcribe(audio, mime_type, opts \\ []) do
    primary = Keyword.get(opts, :engine) || Settings.transcription_engine()
    fallback = Keyword.get(opts, :fallback, Settings.fallback_transcription_engine())

    case retry(audio, mime_type, primary, opts, 1) do
      {:ok, transcript} -> {:ok, transcript}
      {:error, error} -> try_fallback(audio, mime_type, fallback, opts, error)
    end
  end

  defp retry(audio, mime_type, engine, opts, attempt) do
    max_attempts = Settings.max_retries()

    case call(engine, audio, mime_type) do
      {:ok, transcript} ->
        {:ok, transcript}

      {:error, error} ->
        delay = Settings.retry_delay_ms() * attempt
        notify(opts, attempt, max_attempts, delay)
        sleep(opts, delay)

        if attempt >= max_attempts do
          {:error, error}
        else
          retry(audio, mime_type, engine, opts, attempt + 1)
        end
    end
  end

  defp try_fallback(_audio, _mime_type, nil, _opts, error), do: {:error, describe(error)}

  defp try_fallback(audio, mime_type, fallback, opts, error) do
    notify(opts, :fallback, nil, 0)

    case call(fallback, audio, mime_type) do
      {:ok, transcript} -> {:ok, transcript}
      {:error, fallback_error} -> {:error, describe(error) <> "\n\n" <> describe(fallback_error)}
    end
  end

  defp call(engine, audio, mime_type) do
    case resolve(engine) do
      {:ok, {module, model}} ->
        try do
          module.transcribe(audio, mime_type, model)
        rescue
          exception -> {:error, exception}
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve({module, model}) when is_atom(module), do: {:ok, {module, model}}

  defp resolve(name) when is_binary(name) do
    case Map.fetch(@engines, name) do
      {:ok, engine} ->
        {:ok, engine}

      :error ->
        {:error, "Invalid engine name: #{name}. Available engines: #{Enum.join(names(), ", ")}"}
    end
  end

  defp resolve(other), do: {:error, "Invalid engine: #{inspect(other)}"}

  defp notify(opts, attempt, max_attempts, delay) do
    case Keyword.get(opts, :on_retry) do
      nil -> :ok
      fun -> fun.(attempt, max_attempts, delay)
    end
  end

  defp sleep(_opts, 0), do: :ok

  defp sleep(opts, delay) do
    case Keyword.get(opts, :sleep) do
      nil -> Process.sleep(delay)
      fun -> fun.(delay)
    end
  end

  defp describe(%{__exception__: true} = exception),
    do: "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"

  defp describe(error) when is_binary(error), do: error
  defp describe(error), do: inspect(error)
end
