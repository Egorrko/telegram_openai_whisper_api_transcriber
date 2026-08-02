defmodule Mix.Tasks.ImportDjangoTest do
  @moduledoc """
  The one-shot SQLite → Postgres migration, against a database built with the
  source's own schema (`src/bot/migrations/0001_initial.py`).
  """

  use TelegramVoiceTranscriberAsh.DataCase, async: false

  import ExUnit.CaptureIO

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Metering.Payment
  alias TelegramVoiceTranscriberAsh.Metering.TranscriptionLog
  alias TelegramVoiceTranscriberAsh.Settings

  @schema """
  CREATE TABLE bot_user (
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    hashed_user_id VARCHAR(255) NOT NULL UNIQUE,
    left_free_seconds INTEGER NOT NULL,
    left_purchased_seconds INTEGER NOT NULL,
    last_free_reset_at TEXT NOT NULL,
    warned_at TEXT NULL
  );
  CREATE TABLE bot_transcription (
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    audio_duration INTEGER NOT NULL,
    transcription_time REAL NOT NULL,
    user_id INTEGER NOT NULL REFERENCES bot_user(id)
  );
  CREATE TABLE bot_payment (
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    payment_id VARCHAR(255) NOT NULL,
    total_amount INTEGER NOT NULL,
    user_id INTEGER NOT NULL REFERENCES bot_user(id)
  );
  """

  @rows """
  INSERT INTO bot_user VALUES
    (1, '2026-01-01 00:00:00', '2026-01-01 00:00:00', 'aaa', 900, 600,
     '2026-07-20 10:30:00.123456', '2026-07-25 11:00:00'),
    (2, '2026-01-01 00:00:00', '2026-01-01 00:00:00', 'bbb', 0, 0,
     '2026-06-01 00:00:00', NULL);
  INSERT INTO bot_transcription VALUES
    (1, '2026-07-21 10:00:00', '2026-07-21 10:00:00', 42, 3.5, 1),
    (2, '2026-07-22 10:00:00', '2026-07-22 10:00:00', 17, -1.0, 1),
    (3, '2026-07-23 10:00:00', '2026-07-23 10:00:00', 8, 1.25, 2);
  INSERT INTO bot_payment VALUES
    (1, '2026-07-24 10:00:00', '2026-07-24 10:00:00', 'charge-1', 50, 1),
    (2, '2026-07-25 10:00:00', '2026-07-25 10:00:00', 'charge-1', 50, 1);
  """

  setup do
    path = Path.join(System.tmp_dir!(), "django-#{System.unique_integer([:positive])}.sqlite3")
    {_output, 0} = System.cmd("sqlite3", [path, @schema <> @rows], stderr_to_stdout: true)
    on_exit(fn -> File.rm(path) end)

    {:ok, database: path}
  end

  # Mix.shell().info writes to stdout and .error to stderr; the test wants both.
  defp import!(path) do
    errors =
      capture_io(:stderr, fn ->
        send(self(), {:stdout, capture_io(fn -> Mix.Tasks.ImportDjango.run([path]) end)})
      end)

    assert_received {:stdout, output}
    output <> errors
  end

  test "balances, timestamps and the warning latch survive the move", %{database: path} do
    import!(path)

    imported = Metering.get_subscriber!("aaa")
    assert imported.left_free_seconds == 900
    assert imported.left_purchased_seconds == 600
    assert imported.last_free_reset_at == ~U[2026-07-20 10:30:00.123456Z]
    assert imported.warned_at == ~U[2026-07-25 11:00:00.000000Z]

    never_warned = Metering.get_subscriber!("bbb")
    assert is_nil(never_warned.warned_at)
    # A zero free balance is imported as-is; the reset rule repairs it later.
    assert never_warned.left_free_seconds == 0
  end

  test "the -1 sentinel becomes an explicit failure", %{database: path} do
    import!(path)

    logs = TranscriptionLog |> Ash.read!() |> Enum.sort_by(& &1.audio_duration)

    assert [
             %{audio_duration: 8, status: :succeeded, duration_ms: 1250},
             %{audio_duration: 17, status: :failed, duration_ms: nil},
             %{audio_duration: 42, status: :succeeded, duration_ms: 3500}
           ] = logs
  end

  test "a duplicate charge ID is reported and skipped, not crashed on", %{database: path} do
    output = import!(path)

    assert output =~ "skipping duplicate charge charge-1"
    assert [payment] = Ash.read!(Payment)
    assert payment.stars == 50
    assert payment.seconds_credited == 50 * Settings.currency_rate_seconds()
  end

  test "re-running the import changes nothing", %{database: path} do
    import!(path)
    first = {Ash.count!(Payment), Metering.get_subscriber!("aaa").left_free_seconds}

    import!(path)

    assert {Ash.count!(Payment), Metering.get_subscriber!("aaa").left_free_seconds} == first
  end
end
