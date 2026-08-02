defmodule TelegramVoiceTranscriberAsh.Settings do
  @moduledoc """
  Product settings, ported from the source bot's `src/config/settings.py`.

  Values are written by `config/runtime.exs` from the same environment
  variables the Django bot used, so a deployment keeps its existing `.env`.
  """

  @app :telegram_voice_transcriber_ash

  @doc "Free allowance granted per 30-day period, in seconds (`AVAILABLE_MINUTES`)."
  def available_seconds, do: get(:available_seconds, 30 * 60)

  @doc "Combined balance below which the user is warned once (`LEFT_WARNING_MINUTES`)."
  def warning_seconds, do: get(:left_warning_seconds, 10 * 60)

  @doc "Attempts against the primary engine before falling back (`MAX_RETRIES`)."
  def max_retries, do: get(:max_retries, 3)

  @doc "Base backoff between attempts; the delay is `retry_delay_ms * attempt` (`RETRY_DELAY`)."
  def retry_delay_ms, do: get(:retry_delay_ms, 1_000)

  def transcription_engine, do: get(:transcription_engine, "gemini-3.5-flash-lite")
  def fallback_transcription_engine, do: get(:fallback_transcription_engine)

  def telegram_token, do: get(:telegram_token)

  @doc "Set to false to run a node that serves the console but does not poll Telegram."
  def start_bot?, do: get(:start_bot, true)

  def gemini_api_key, do: get(:gemini_api_key)
  def openai_api_key, do: get(:openai_api_key)
  def elevenlabs_api_key, do: get(:elevenlabs_api_key)

  defp get(key, default \\ nil), do: Application.get_env(@app, key, default)
end
