defmodule TelegramVoiceTranscriberAsh.Metering.Payment.Credit do
  @moduledoc """
  Port of `db.make_payment`, with the two things the source got wrong: the
  credit is idempotent on the Telegram charge ID (D2), and it clears the
  low-balance warning latch so a user who tops up can be warned again (D5).
  """

  use Ash.Resource.Actions.Implementation

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @impl true
  def run(input, _opts, _context) do
    %{hashed_user_id: hashed_user_id, charge_id: charge_id, stars: stars} = input.arguments

    case Metering.payment_by_charge_id(charge_id, not_found_error?: false) do
      {:ok, nil} -> {:ok, record(hashed_user_id, charge_id, stars)}
      {:ok, existing} -> {:ok, existing}
      {:error, error} -> {:error, error}
    end
  end

  defp record(hashed_user_id, charge_id, stars) do
    seconds = stars * Settings.currency_rate_seconds()
    subscriber = Metering.find_or_register!(hashed_user_id)

    Metering.credit_seconds!(subscriber, seconds)

    Metering.record_payment!(%{
      charge_id: charge_id,
      stars: stars,
      seconds_credited: seconds,
      subscriber_id: subscriber.id
    })
  end
end
