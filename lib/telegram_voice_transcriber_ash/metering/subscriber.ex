defmodule TelegramVoiceTranscriberAsh.Metering.Subscriber do
  @moduledoc """
  A metered account, identified only by the SHA-256 hash of the Telegram user
  ID (R1). Holds the free and purchased second balances.
  """

  use Ash.Resource,
    otp_app: :telegram_voice_transcriber_ash,
    domain: TelegramVoiceTranscriberAsh.Metering,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource]

  alias TelegramVoiceTranscriberAsh.Metering.Subscriber.Reserve

  admin do
    read_actions [:read]
  end

  postgres do
    table "subscribers"
    repo TelegramVoiceTranscriberAsh.Repo

    check_constraints do
      # Defect D1 in the analysis: the source could drive either balance
      # negative. The database now refuses to store one.
      check_constraint :left_free_seconds,
        name: "left_free_seconds_non_negative",
        check: "left_free_seconds >= 0",
        message: "free balance cannot go negative"

      check_constraint :left_purchased_seconds,
        name: "left_purchased_seconds_non_negative",
        check: "left_purchased_seconds >= 0",
        message: "purchased balance cannot go negative"
    end
  end

  actions do
    defaults [:read]

    create :find_or_register do
      description "R2: lazily create the account on first contact, seeded with the free allowance."
      accept [:hashed_user_id]
      upsert? true
      upsert_identity :unique_hashed_user_id
      # Nothing may be overwritten on conflict — this action only ever reads
      # back an existing balance.
      upsert_fields [:hashed_user_id]
    end

    action :reserve, :map do
      description """
      R3/R5/R6: reset the monthly allowance if it is stale, then decide whether
      this transcription may proceed. Returns
      `%{status: :ok | :warn | :exceeded, subscriber: subscriber}`.
      """

      argument :hashed_user_id, :string, allow_nil?: false
      argument :seconds, :integer, allow_nil?: false, constraints: [min: 0]

      run Reserve
    end

    update :apply_free_reset do
      description "R3: restore the free allowance and clear the warning latch."

      argument :available_seconds, :integer,
        allow_nil?: false,
        default: &TelegramVoiceTranscriberAsh.Settings.available_seconds/0

      change set_attribute(:left_free_seconds, arg(:available_seconds))
      change set_attribute(:last_free_reset_at, &DateTime.utc_now/0)
      change set_attribute(:warned_at, nil)
    end

    update :mark_warned do
      description "R6: latch the low-balance warning so it is only shown once."
      change set_attribute(:warned_at, &DateTime.utc_now/0)
    end

    update :credit_seconds do
      description "R9: add purchased seconds. Clearing the latch fixes defect D5."
      argument :seconds, :integer, allow_nil?: false, constraints: [min: 1]

      change atomic_update(:left_purchased_seconds, expr(left_purchased_seconds + ^arg(:seconds)))
      change set_attribute(:warned_at, nil)
    end

    # R7: spend free seconds first, the shortfall from purchased seconds.
    #
    # Both columns are updated in one atomic statement evaluated against the
    # stored row, so concurrent voice messages cannot clobber each other the
    # way they do in the source (defect D1).
    #
    # ponytail: the balance is clamped at zero rather than reserved up front,
    # so a burst of concurrent messages can overspend by at most one message's
    # duration. Add a reservation row if that ever matters.
    update :debit do
      description "R7: spend free seconds first, the shortfall from purchased seconds."
      argument :seconds, :integer, allow_nil?: false, constraints: [min: 0]

      change atomic_update(
               :left_free_seconds,
               expr(fragment("GREATEST(? - ?, 0)", left_free_seconds, ^arg(:seconds)))
             )

      change atomic_update(
               :left_purchased_seconds,
               expr(
                 fragment(
                   "GREATEST(? - GREATEST(? - ?, 0), 0)",
                   left_purchased_seconds,
                   ^arg(:seconds),
                   left_free_seconds
                 )
               )
             )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :hashed_user_id, :string do
      allow_nil? false
      public? true
      description "sha256(str(telegram_user_id)) as lowercase hex — see Bot.Identity"
    end

    attribute :left_free_seconds, :integer do
      allow_nil? false
      public? true
      default &TelegramVoiceTranscriberAsh.Settings.available_seconds/0
    end

    attribute :left_purchased_seconds, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :last_free_reset_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :warned_at, :utc_datetime_usec, public?: true

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :transcription_logs, TelegramVoiceTranscriberAsh.Metering.TranscriptionLog
  end

  calculations do
    calculate :total_seconds, :integer, expr(left_free_seconds + left_purchased_seconds)
  end

  identities do
    identity :unique_hashed_user_id, [:hashed_user_id]
  end
end
