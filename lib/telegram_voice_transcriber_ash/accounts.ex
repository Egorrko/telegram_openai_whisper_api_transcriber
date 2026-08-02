defmodule TelegramVoiceTranscriberAsh.Accounts do
  use Ash.Domain, otp_app: :telegram_voice_transcriber_ash, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource TelegramVoiceTranscriberAsh.Accounts.Token
    resource TelegramVoiceTranscriberAsh.Accounts.User
  end
end
