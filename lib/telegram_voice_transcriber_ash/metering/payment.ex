defmodule TelegramVoiceTranscriberAsh.Metering.Payment do
  @moduledoc """
  A Telegram Stars purchase, and the seconds it bought.

  `charge_id` is unique here, which it was not in the source (defect D2): a
  redelivered `successful_payment` update can no longer credit an account
  twice.
  """

  use Ash.Resource,
    otp_app: :telegram_voice_transcriber_ash,
    domain: TelegramVoiceTranscriberAsh.Metering,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource]

  alias TelegramVoiceTranscriberAsh.Metering.Payment.Credit

  admin do
    read_actions [:read]
  end

  postgres do
    table "payments"
    repo TelegramVoiceTranscriberAsh.Repo
  end

  actions do
    defaults [:read]

    read :by_charge_id do
      description "Look up a purchase by the Telegram charge ID."
      get? true
      argument :charge_id, :string, allow_nil?: false
      filter expr(charge_id == ^arg(:charge_id))
    end

    create :record do
      description "Write the purchase row. Use :credit — this does not move the balance."
      accept [:charge_id, :stars, :seconds_credited, :subscriber_id]
    end

    action :credit, :struct do
      description """
      R9: credit `stars * CURRENCY_RATE` seconds and record the purchase, in
      one transaction. Idempotent on `charge_id`: a repeat delivery returns the
      existing purchase and moves no balance.
      """

      constraints instance_of: __MODULE__

      argument :hashed_user_id, :string, allow_nil?: false
      argument :charge_id, :string, allow_nil?: false
      argument :stars, :integer, allow_nil?: false, constraints: [min: 1]

      transaction? true
      run Credit
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :charge_id, :string do
      allow_nil? false
      public? true
      description "telegram_payment_charge_id — the idempotency key"
    end

    attribute :stars, :integer do
      allow_nil? false
      public? true
    end

    # Recorded rather than recomputed: CURRENCY_RATE is runtime configuration,
    # and after it changes `stars * rate` no longer describes what was granted.
    attribute :seconds_credited, :integer do
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :subscriber, TelegramVoiceTranscriberAsh.Metering.Subscriber do
      allow_nil? false
      public? true
      attribute_public? true
    end
  end

  identities do
    identity :unique_charge_id, [:charge_id]
  end
end
