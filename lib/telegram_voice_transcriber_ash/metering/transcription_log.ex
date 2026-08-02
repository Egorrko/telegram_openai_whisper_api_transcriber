defmodule TelegramVoiceTranscriberAsh.Metering.TranscriptionLog do
  @moduledoc """
  Anonymous, append-only usage log. Deliberately holds no audio and no
  transcript text — only how long the audio was and how long we took.

  The source's `transcription_time = -1` failure sentinel is replaced by an
  explicit `status` (analysis section 10).
  """

  use Ash.Resource,
    otp_app: :telegram_voice_transcriber_ash,
    domain: TelegramVoiceTranscriberAsh.Metering,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource]

  admin do
    read_actions [:read]
  end

  postgres do
    table "transcription_logs"
    repo TelegramVoiceTranscriberAsh.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:audio_duration, :duration_ms, :status, :subscriber_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :audio_duration, :integer do
      allow_nil? false
      public? true
      description "Length of the source audio in seconds — the metered quantity"
    end

    attribute :duration_ms, :integer do
      public? true
      description "Wall-clock time the engine took; nil when the pipeline failed"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:succeeded, :failed]
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
end
