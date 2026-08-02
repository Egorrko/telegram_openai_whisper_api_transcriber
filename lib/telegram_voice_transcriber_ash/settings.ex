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

  @doc "Seconds of recognition one Telegram Star buys (`CURRENCY_RATE`)."
  def currency_rate_seconds, do: get(:currency_rate_seconds, 10 * 60)

  @doc "Contact shown by /paysupport, which Telegram requires for Stars payments."
  def support_username, do: get(:support_username)

  def transcription_engine, do: get(:transcription_engine, "gemini-3.5-flash-lite")
  def fallback_transcription_engine, do: get(:fallback_transcription_engine)

  def telegram_token, do: get(:telegram_token)

  @doc "Bot handle, including the @. A group reply mentioning it triggers transcription."
  def bot_username, do: get(:bot_username)

  @doc "Chats where every voice message and video note is transcribed automatically."
  def allowed_chat_ids, do: get(:allowed_chat_ids, [])

  @doc "Chats whose voice, audio and video notes are forwarded to the operator."
  def forward_chat_ids, do: get(:forward_chat_ids, [])

  @doc "Raw Telegram ID of the operator receiving forwarded messages. Not hashed."
  def admin_id, do: get(:admin_id)

  @doc "Set to false to run a node that serves the console but does not poll Telegram."
  def start_bot?, do: get(:start_bot, true)

  def gemini_api_key, do: get(:gemini_api_key)
  def openai_api_key, do: get(:openai_api_key)
  def elevenlabs_api_key, do: get(:elevenlabs_api_key)

  defp get(key, default \\ nil), do: Application.get_env(@app, key, default)
end
