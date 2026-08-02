defmodule TelegramVoiceTranscriberAsh.Metering.Subscriber.Reserve do
  @moduledoc """
  Port of `db.prepare_user_for_transcription`: find or create the account,
  apply the lazy 30-day free reset (R3), then decide (R5/R6).

  The source distinguished `"success"` from `"warned"` — both continue, and
  only the first of them shows a message — so this returns `:ok` for either and
  `:warn` only when the warning must actually be sent.
  """

  use Ash.Resource.Actions.Implementation

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings

  @reset_after_days 30

  @impl true
  def run(input, _opts, _context) do
    subscriber =
      input.arguments.hashed_user_id
      |> Metering.find_or_register!()
      |> reset_if_stale()

    {:ok, decide(subscriber, input.arguments.seconds)}
  end

  defp reset_if_stale(subscriber) do
    cutoff = DateTime.add(DateTime.utc_now(), -@reset_after_days, :day)

    if DateTime.before?(subscriber.last_free_reset_at, cutoff) do
      Metering.apply_free_reset!(subscriber)
    else
      subscriber
    end
  end

  defp decide(subscriber, seconds) do
    left = subscriber.left_free_seconds + subscriber.left_purchased_seconds

    cond do
      left < seconds ->
        %{status: :exceeded, subscriber: subscriber}

      left < Settings.warning_seconds() and is_nil(subscriber.warned_at) ->
        %{status: :warn, subscriber: Metering.mark_warned!(subscriber)}

      true ->
        %{status: :ok, subscriber: subscriber}
    end
  end
end
