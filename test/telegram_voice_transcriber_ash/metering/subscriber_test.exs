defmodule TelegramVoiceTranscriberAsh.Metering.SubscriberTest do
  @moduledoc """
  Port of `src/bot/tests/transcription_tests.py` and `edge_cases_tests.py`,
  plus the concurrency case the source would fail (defect D1).
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: true

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Metering.Subscriber
  alias TelegramVoiceTranscriberAsh.Settings

  defp hash, do: "hash-#{System.unique_integer([:positive])}"

  defp subscriber(attrs) do
    defaults = %{
      hashed_user_id: hash(),
      left_free_seconds: Settings.available_seconds(),
      left_purchased_seconds: 0,
      last_free_reset_at: DateTime.utc_now()
    }

    Ash.Seed.seed!(Subscriber, Map.merge(defaults, attrs))
  end

  defp reload(subscriber), do: Ash.reload!(subscriber)

  describe "find_or_register (R2)" do
    test "a new account starts with the configured free allowance" do
      subscriber = Metering.find_or_register!(hash())

      assert subscriber.left_free_seconds == Settings.available_seconds()
      assert subscriber.left_purchased_seconds == 0
      assert is_nil(subscriber.warned_at)
    end

    test "an existing account is returned untouched" do
      existing = subscriber(%{left_free_seconds: 7, left_purchased_seconds: 3})

      found = Metering.find_or_register!(existing.hashed_user_id)

      assert found.id == existing.id
      assert found.left_free_seconds == 7
      assert found.left_purchased_seconds == 3
    end
  end

  describe "reserve (R5/R6)" do
    # Comfortably above the warning threshold, so these cases test the balance
    # check and not the warning latch.
    defp plenty, do: Settings.warning_seconds() + 600

    test "enough free seconds" do
      %{hashed_user_id: id} =
        subscriber(%{left_free_seconds: plenty(), left_purchased_seconds: 0})

      assert %{status: :ok} = Metering.reserve!(id, 60)
    end

    test "enough purchased seconds" do
      %{hashed_user_id: id} =
        subscriber(%{left_free_seconds: 0, left_purchased_seconds: plenty()})

      assert %{status: :ok} = Metering.reserve!(id, 60)
    end

    test "the check is against the combined balance" do
      half = div(plenty(), 2) + 1

      %{hashed_user_id: id} =
        subscriber(%{left_free_seconds: half, left_purchased_seconds: half})

      assert %{status: :ok} = Metering.reserve!(id, plenty())
    end

    test "an insufficient combined balance is refused" do
      %{hashed_user_id: id} = subscriber(%{left_free_seconds: 30, left_purchased_seconds: 20})

      assert %{status: :exceeded} = Metering.reserve!(id, 60)
    end

    test "the exact balance is allowed" do
      # Already warned, so the last 60 seconds are spendable without a warning.
      %{hashed_user_id: id} =
        subscriber(%{
          left_free_seconds: 60,
          left_purchased_seconds: 0,
          warned_at: DateTime.utc_now()
        })

      assert %{status: :ok} = Metering.reserve!(id, 60)
    end

    test "the low-balance warning is shown once and latched" do
      warning = Settings.warning_seconds()

      %{hashed_user_id: id} =
        subscriber(%{left_free_seconds: warning - 50, left_purchased_seconds: 0})

      assert %{status: :warn, subscriber: warned} = Metering.reserve!(id, 60)
      assert warned.warned_at

      assert %{status: :ok} = Metering.reserve!(id, 60)
    end
  end

  describe "the 30-day free reset (R3)" do
    test "fires when the last reset is older than 30 days, and clears the latch" do
      long_ago = DateTime.add(DateTime.utc_now(), -31, :day)

      existing =
        subscriber(%{left_free_seconds: 50, last_free_reset_at: long_ago, warned_at: long_ago})

      assert %{subscriber: reset} = Metering.reserve!(existing.hashed_user_id, 10)

      assert reset.left_free_seconds == Settings.available_seconds()
      assert is_nil(reset.warned_at)
      assert DateTime.to_date(reset.last_free_reset_at) == Date.utc_today()
    end

    test "does not fire within 30 days" do
      recently = DateTime.add(DateTime.utc_now(), -10, :day)
      existing = subscriber(%{left_free_seconds: 50, last_free_reset_at: recently})

      Metering.reserve!(existing.hashed_user_id, 10)

      assert reload(existing).left_free_seconds == 50
    end
  end

  describe "debit (R7)" do
    test "spends free seconds only" do
      debited =
        %{left_free_seconds: 100, left_purchased_seconds: 50}
        |> subscriber()
        |> Metering.debit!(60)

      assert debited.left_free_seconds == 40
      assert debited.left_purchased_seconds == 50
    end

    test "spends free seconds first, then purchased" do
      debited =
        %{left_free_seconds: 50, left_purchased_seconds: 100}
        |> subscriber()
        |> Metering.debit!(80)

      assert debited.left_free_seconds == 0
      assert debited.left_purchased_seconds == 70
    end

    test "spends purchased seconds when there are no free ones" do
      debited =
        %{left_free_seconds: 0, left_purchased_seconds: 100}
        |> subscriber()
        |> Metering.debit!(70)

      assert debited.left_free_seconds == 0
      assert debited.left_purchased_seconds == 30
    end

    test "an exact free-seconds spend leaves purchased seconds untouched" do
      debited =
        %{left_free_seconds: 120, left_purchased_seconds: 500}
        |> subscriber()
        |> Metering.debit!(120)

      assert debited.left_free_seconds == 0
      assert debited.left_purchased_seconds == 500
    end

    test "two debits against the same stale balance cannot overdraw it (D1)" do
      # Both callers read the account before either writes — the interleaving
      # that drives the source's balances negative.
      first = subscriber(%{left_free_seconds: 100, left_purchased_seconds: 0})
      second = reload(first)

      Metering.debit!(first, 60)
      Metering.debit!(second, 60)

      final = reload(first)
      assert final.left_free_seconds == 0
      assert final.left_purchased_seconds == 0
    end
  end

  describe "the usage log" do
    test "records a success and a failure without any transcript text" do
      subscriber = subscriber(%{})

      success =
        Metering.record_transcription!(%{
          subscriber_id: subscriber.id,
          audio_duration: 42,
          duration_ms: 1234,
          status: :succeeded
        })

      failure =
        Metering.record_transcription!(%{
          subscriber_id: subscriber.id,
          audio_duration: 42,
          status: :failed
        })

      assert success.status == :succeeded
      assert success.duration_ms == 1234
      assert failure.status == :failed
      assert is_nil(failure.duration_ms)
    end
  end
end
