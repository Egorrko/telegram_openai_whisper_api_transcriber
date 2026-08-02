defmodule TelegramVoiceTranscriberAsh.Metering.ResetTriggerTest do
  @moduledoc """
  The nightly free-allowance sweep. Fixes R4: the source only ever reset on the
  next transcription, so an account nobody used stayed stale indefinitely.
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: false
  use Oban.Testing, repo: TelegramVoiceTranscriberAsh.Repo

  alias TelegramVoiceTranscriberAsh.Metering.Subscriber
  alias TelegramVoiceTranscriberAsh.Settings

  defp subscriber(attrs) do
    defaults = %{
      hashed_user_id: "hash-#{System.unique_integer([:positive])}",
      left_free_seconds: 0,
      left_purchased_seconds: 0,
      last_free_reset_at: DateTime.utc_now()
    }

    Ash.Seed.seed!(Subscriber, Map.merge(defaults, attrs))
  end

  defp run_sweep do
    AshOban.schedule_and_run_triggers(Subscriber, drain_queues?: true)
  end

  test "a dormant account gets its allowance back without ever using the bot" do
    long_ago = DateTime.add(DateTime.utc_now(), -31, :day)
    dormant = subscriber(%{last_free_reset_at: long_ago, warned_at: long_ago})

    run_sweep()

    reset = Ash.reload!(dormant)
    assert reset.left_free_seconds == Settings.available_seconds()
    assert is_nil(reset.warned_at)
    assert DateTime.to_date(reset.last_free_reset_at) == Date.utc_today()
  end

  test "an account reset less than 30 days ago is left alone" do
    recent = subscriber(%{last_free_reset_at: DateTime.add(DateTime.utc_now(), -10, :day)})

    run_sweep()

    assert Ash.reload!(recent).left_free_seconds == 0
  end

  test "purchased seconds are never touched by the reset" do
    long_ago = DateTime.add(DateTime.utc_now(), -40, :day)
    topped_up = subscriber(%{last_free_reset_at: long_ago, left_purchased_seconds: 1234})

    run_sweep()

    assert Ash.reload!(topped_up).left_purchased_seconds == 1234
  end
end
