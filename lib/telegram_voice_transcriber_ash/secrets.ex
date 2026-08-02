defmodule TelegramVoiceTranscriberAsh.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        TelegramVoiceTranscriberAsh.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:telegram_voice_transcriber_ash, :token_signing_secret)
  end
end
