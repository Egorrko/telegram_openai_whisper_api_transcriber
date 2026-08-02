defmodule TelegramVoiceTranscriberAsh.Bot.Identity do
  @moduledoc """
  The one-way mapping from a Telegram user ID to the only identifier this
  product stores (R1).

  The digest must stay bit-identical to the source bot's
  `hashlib.sha256(str(user_id).encode()).hexdigest()` — a different digest
  silently orphans every existing balance.
  """

  @spec hash(integer() | String.t()) :: String.t()
  def hash(telegram_user_id) do
    :sha256
    |> :crypto.hash(to_string(telegram_user_id))
    |> Base.encode16(case: :lower)
  end
end
