defmodule TelegramVoiceTranscriberAsh.Metering do
  @moduledoc """
  The quota ledger: one metered account per Telegram user, and the anonymous
  usage log. Replaces the source bot's `bot.User` and `bot.Transcription`.
  """

  use Ash.Domain, otp_app: :telegram_voice_transcriber_ash, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource TelegramVoiceTranscriberAsh.Metering.Subscriber do
      define :find_or_register, args: [:hashed_user_id]
      define :get_subscriber, action: :read, get_by: [:hashed_user_id]
      define :reserve, args: [:hashed_user_id, :seconds]
      define :debit, args: [:seconds]
      define :mark_warned
      define :apply_free_reset
    end

    resource TelegramVoiceTranscriberAsh.Metering.TranscriptionLog do
      define :record_transcription, action: :record
    end
  end
end
