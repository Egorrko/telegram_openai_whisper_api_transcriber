defmodule Mix.Tasks.ImportDjango do
  @shortdoc "Imports the source bot's SQLite database into Postgres"

  @moduledoc """
  One-shot migration of the Django bot's `data/db.sqlite3` into this
  application's Postgres database.

      mix import_django ../telegram_voice_transciber/data/db.sqlite3

  Run it against a **stopped** bot. Both halves running at once would split the
  balances between two databases.

  Reading is delegated to the `sqlite3` CLI rather than an Elixir driver: this
  runs once, and a driver would be a permanent dependency for it.

  What the shapes translate to (analysis section 10):

    * integer primary keys become UUIDs — nothing outside the database ever
      referenced them;
    * `Transcription.transcription_time == -1` was the failure marker, and
      becomes `status: :failed` with no duration;
    * `Payment.payment_id` becomes `charge_id`, which is unique here. Duplicates
      in the source data are reported and skipped, and `seconds_credited` is
      reconstructed from the *current* `CURRENCY_RATE`, which is the best the
      source's data allows.

  The import is idempotent on `hashed_user_id` and `charge_id`, so it can be
  re-run after fixing a problem. Balances are taken from the source verbatim,
  including accounts created outside `get_or_create_user` whose free balance is
  `0`; the reset rule corrects those on its own.
  """

  use Mix.Task

  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Metering.Payment
  alias TelegramVoiceTranscriberAsh.Settings

  @requirements ["app.start"]

  @impl Mix.Task
  def run([database]) do
    unless File.exists?(database), do: Mix.raise("No such database: #{database}")
    unless System.find_executable("sqlite3"), do: Mix.raise("The sqlite3 CLI is required")

    subscribers = import_subscribers(database)

    Mix.shell().info("subscribers: #{map_size(subscribers)}")
    Mix.shell().info("transcription logs: #{import_logs(database, subscribers)}")
    Mix.shell().info("payments: #{import_payments(database, subscribers)}")
  end

  def run(_argv), do: Mix.raise("Usage: mix import_django PATH_TO_DB_SQLITE3")

  defp import_subscribers(database) do
    database
    |> query(
      "SELECT id, hashed_user_id, left_free_seconds, left_purchased_seconds, " <>
        "last_free_reset_at, warned_at FROM bot_user"
    )
    |> Map.new(fn row ->
      subscriber =
        row["hashed_user_id"]
        |> Metering.find_or_register!()
        |> Metering.import_subscriber!(%{
          left_free_seconds: row["left_free_seconds"],
          left_purchased_seconds: row["left_purchased_seconds"],
          last_free_reset_at: timestamp(row["last_free_reset_at"]),
          warned_at: timestamp(row["warned_at"])
        })

      {row["id"], subscriber}
    end)
  end

  defp import_logs(database, subscribers) do
    database
    |> query("SELECT user_id, audio_duration, transcription_time FROM bot_transcription")
    |> Enum.count(fn row ->
      case Map.fetch(subscribers, row["user_id"]) do
        {:ok, subscriber} ->
          Metering.record_transcription!(%{
            subscriber_id: subscriber.id,
            audio_duration: row["audio_duration"],
            status: status(row["transcription_time"]),
            duration_ms: duration_ms(row["transcription_time"])
          })

          true

        :error ->
          Mix.shell().error("skipping a log row whose user #{row["user_id"]} is missing")
          false
      end
    end)
  end

  defp import_payments(database, subscribers) do
    database
    |> query("SELECT user_id, payment_id, total_amount FROM bot_payment")
    |> Enum.count(fn row ->
      with {:ok, subscriber} <- Map.fetch(subscribers, row["user_id"]),
           {:ok, nil} <- Metering.payment_by_charge_id(row["payment_id"], not_found_error?: false) do
        Metering.record_payment!(%{
          subscriber_id: subscriber.id,
          charge_id: row["payment_id"],
          stars: row["total_amount"],
          seconds_credited: row["total_amount"] * Settings.currency_rate_seconds()
        })

        true
      else
        {:ok, %Payment{}} ->
          Mix.shell().error("skipping duplicate charge #{row["payment_id"]}")
          false

        :error ->
          Mix.shell().error("skipping a payment whose user #{row["user_id"]} is missing")
          false
      end
    end)
  end

  # The source recorded seconds as a float, with -1 standing in for a failure.
  defp status(-1), do: :failed
  defp status(-1.0), do: :failed
  defp status(_), do: :succeeded

  defp duration_ms(seconds) when seconds in [-1, -1.0], do: nil
  defp duration_ms(seconds), do: round(seconds * 1000)

  defp timestamp(nil), do: nil
  defp timestamp(""), do: nil

  # Django writes UTC as "YYYY-MM-DD HH:MM:SS[.ffffff]" with no zone marker.
  defp timestamp(value) do
    value
    |> String.replace(" ", "T")
    |> NaiveDateTime.from_iso8601!()
    |> DateTime.from_naive!("Etc/UTC")
  end

  defp query(database, sql) do
    case System.cmd("sqlite3", [database, "-json", sql], stderr_to_stdout: true) do
      {"", 0} -> []
      {output, 0} -> Jason.decode!(output)
      {output, status} -> Mix.raise("sqlite3 exited with #{status}:\n#{output}")
    end
  end
end
