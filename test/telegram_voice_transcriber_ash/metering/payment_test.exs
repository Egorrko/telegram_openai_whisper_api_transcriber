defmodule TelegramVoiceTranscriberAsh.Metering.PaymentTest do
  @moduledoc """
  Port of `test_make_payment` in `src/bot/tests/user_and_payment_tests.py`,
  plus the two cases the source would fail: a redelivered charge (D2) and the
  warning latch after a top-up (D5).
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: true

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Metering.Payment
  alias TelegramVoiceTranscriberAsh.Metering.Subscriber
  alias TelegramVoiceTranscriberAsh.Settings

  defp hash, do: "hash-#{System.unique_integer([:positive])}"
  defp charge, do: "charge-#{System.unique_integer([:positive])}"

  defp subscriber(attrs \\ %{}) do
    defaults = %{
      hashed_user_id: hash(),
      left_free_seconds: 0,
      left_purchased_seconds: 0,
      last_free_reset_at: DateTime.utc_now()
    }

    Ash.Seed.seed!(Subscriber, Map.merge(defaults, attrs))
  end

  defp payments_of(subscriber) do
    Payment |> Ash.read!() |> Enum.filter(&(&1.subscriber_id == subscriber.id))
  end

  test "one star buys CURRENCY_RATE seconds and the purchase is recorded (R9)" do
    existing = subscriber(%{left_purchased_seconds: 100})
    charge_id = charge()

    payment = Metering.credit_payment!(existing.hashed_user_id, charge_id, 50)

    assert payment.stars == 50
    assert payment.charge_id == charge_id
    assert payment.seconds_credited == 50 * Settings.currency_rate_seconds()
    assert payment.subscriber_id == existing.id

    assert Ash.reload!(existing).left_purchased_seconds ==
             100 + 50 * Settings.currency_rate_seconds()
  end

  test "an account that has never been seen is registered on purchase" do
    hashed_user_id = hash()

    payment = Metering.credit_payment!(hashed_user_id, charge(), 1)

    registered = Metering.get_subscriber!(hashed_user_id)
    assert payment.subscriber_id == registered.id

    assert registered.left_purchased_seconds == Settings.currency_rate_seconds()
    assert registered.left_free_seconds == Settings.available_seconds()
  end

  test "a redelivered charge credits nothing the second time (D2)" do
    existing = subscriber()
    charge_id = charge()

    first = Metering.credit_payment!(existing.hashed_user_id, charge_id, 10)
    again = Metering.credit_payment!(existing.hashed_user_id, charge_id, 10)

    assert again.id == first.id
    assert [_only_one] = payments_of(existing)

    assert Ash.reload!(existing).left_purchased_seconds == 10 * Settings.currency_rate_seconds()
  end

  test "buying minutes clears the low-balance warning latch (D5)" do
    existing = subscriber(%{warned_at: DateTime.utc_now()})

    Metering.credit_payment!(existing.hashed_user_id, charge(), 5)

    assert is_nil(Ash.reload!(existing).warned_at)
  end

  test "the charge ID is unique at the database level" do
    existing = subscriber()
    charge_id = charge()

    Metering.credit_payment!(existing.hashed_user_id, charge_id, 1)

    assert {:error, %Ash.Error.Invalid{}} =
             Metering.record_payment(%{
               charge_id: charge_id,
               stars: 1,
               seconds_credited: 600,
               subscriber_id: existing.id
             })
  end
end
