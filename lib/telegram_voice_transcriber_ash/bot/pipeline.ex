defmodule TelegramVoiceTranscriberAsh.Bot.Pipeline do
  @moduledoc """
  One voice message, start to finish: quota check, download, transcription,
  in-place progress edits, delivery, debit, usage log.

  Port of `handle_file` in `src/bot/services/file_processor.py`. As in the
  source, a failure anywhere charges the user nothing but still records the
  attempt, and progress edits are best-effort — a rate-limited edit must never
  kill a transcription.
  """

  require Logger

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Media
  alias TelegramVoiceTranscriberAsh.Bot.Messages
  alias TelegramVoiceTranscriberAsh.Metering
  alias TelegramVoiceTranscriberAsh.Settings
  alias TelegramVoiceTranscriberAsh.Transcribing.Audio
  alias TelegramVoiceTranscriberAsh.Transcribing.Engine
  alias TelegramVoiceTranscriberAsh.Transcribing.ResponseParser
  alias TelegramVoiceTranscriberAsh.Transcribing.RichMessage

  @max_message_length 4096

  @labels %{
    download: "Скачиваю файл...",
    convert: "Достаю звук из видео...",
    transcribe: "Распознаю...",
    sending: "Отправляю результат..."
  }

  @doc """
  Run the pipeline for `media`, replying in `message`'s chat.

  `:hashed_user_id` overrides whose balance is charged. The forwarding path
  needs it: the transcript is delivered next to the operator's copy, but the
  original sender pays for it.
  """
  @spec run(ExGram.Model.Message.t(), Media.t(), keyword()) :: :ok
  def run(message, media, opts \\ []) do
    hashed_user_id =
      Keyword.get_lazy(opts, :hashed_user_id, fn -> Identity.hash(message.from.id) end)

    Sentry.Context.set_user_context(%{id: hashed_user_id})

    case Metering.reserve!(hashed_user_id, media.duration) do
      %{status: :exceeded, subscriber: subscriber} ->
        reply(message, Messages.limit_exceeded(subscriber))
        :ok

      %{status: status, subscriber: subscriber} ->
        if status == :warn, do: reply(message, Messages.limit_warning(subscriber))
        transcribe(message, media, subscriber)
    end
  end

  defp transcribe(message, media, subscriber) do
    progress = reply(message, "Распознаю...")

    case pipeline(message, progress, media) do
      {:ok, duration_ms} ->
        Metering.debit!(subscriber, media.duration)
        record(subscriber, media, :succeeded, duration_ms)

      {:error, {step, reason}} ->
        report_failure(message, progress, step, reason)
        record(subscriber, media, :failed, nil)
    end

    :ok
  end

  defp pipeline(message, progress, media) do
    with {:ok, downloaded} <- step(:download, progress, fn -> download(media) end),
         {:ok, {audio, mime_type}} <- convert(progress, media, downloaded),
         {:ok, {transcript, duration_ms}} <-
           step(:transcribe, progress, fn -> timed(audio, mime_type, progress) end),
         {:ok, _} <-
           step(:sending, progress, [notify?: false], fn ->
             deliver(message, progress, transcript)
           end) do
      {:ok, duration_ms}
    end
  end

  defp step(name, progress, opts \\ [], fun) do
    if Keyword.get(opts, :notify?, true), do: notify(progress, @labels[name])

    case fun.() do
      {:ok, value} -> {:ok, value}
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, {name, describe(reason)}}
    end
  rescue
    exception -> {:error, {name, Exception.message(exception)}}
  end

  defp download(media) do
    with {:ok, file} <- ExGram.get_file(media.file_id, token: Settings.telegram_token()),
         url = ExGram.File.file_url(file, token: Settings.telegram_token()),
         {:ok, %{status: 200, body: body}} <- Req.get(url, receive_timeout: 60_000) do
      {:ok, body}
    else
      {:ok, %{status: status}} -> {:error, "Не удалось скачать файл: HTTP #{status}"}
      {:error, _} = error -> error
    end
  end

  # R16: a video note carries a video stream the engines cannot read.
  defp convert(progress, %{kind: :video_note}, video) do
    step(:convert, progress, fn -> Audio.extract_audio(video) end)
  end

  defp convert(_progress, media, audio), do: {:ok, {audio, media.mime_type}}

  defp timed(audio, mime_type, progress) do
    started = System.monotonic_time(:millisecond)

    case Engine.transcribe(audio, mime_type, on_retry: &retry_notice(progress, &1, &2, &3)) do
      {:ok, transcript} -> {:ok, {transcript, System.monotonic_time(:millisecond) - started}}
      {:error, _} = error -> error
    end
  end

  defp deliver(message, progress, transcript) do
    transcript
    |> ResponseParser.parse()
    |> RichMessage.deliver(
      chat_id: progress.chat.id,
      message_id: progress.message_id,
      reply_to_message_id: message.message_id,
      token: Settings.telegram_token()
    )
  end

  defp record(subscriber, media, status, duration_ms) do
    Metering.record_transcription!(%{
      subscriber_id: subscriber.id,
      audio_duration: media.duration,
      status: status,
      duration_ms: duration_ms
    })
  end

  defp report_failure(message, progress, step, reason) do
    text =
      "Ошибочка (#{step |> Atom.to_string() |> String.upcase()}):\n#{reason}"
      |> String.slice(0, @max_message_length)

    Sentry.capture_message("Transcription pipeline failed",
      extra: %{step: step, reason: reason}
    )

    Logger.warning("transcription pipeline failed at #{step}: #{reason}")

    if not edit(progress, "<pre>#{escape(text)}</pre>", parse_mode: "HTML") do
      # The progress message is gone; say it in a new one instead.
      try do
        reply(message, text)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp retry_notice(progress, :fallback, _max, _delay) do
    notify(progress, "<blockquote>Последняя попытка...</blockquote>", parse_mode: "HTML")
  end

  defp retry_notice(progress, attempt, max, delay) do
    notify(
      progress,
      "<blockquote>Попытка #{attempt}/#{max}...\nЖдите #{div(delay, 1000)} секунд...</blockquote>",
      parse_mode: "HTML"
    )
  end

  defp reply(message, text) do
    case ExGram.send_message(message.chat.id, text,
           reply_parameters: %ExGram.Model.ReplyParameters{message_id: message.message_id},
           token: Settings.telegram_token()
         ) do
      {:ok, sent} -> sent
      {:error, error} -> raise "Не удалось отправить сообщение: #{inspect(error)}"
    end
  end

  # Progress edits are decoration: a failed one must never abort the pipeline.
  defp notify(progress, text, opts \\ []) do
    edit(progress, text, opts)
    :ok
  end

  defp edit(progress, text, opts) do
    [chat_id: progress.chat.id, message_id: progress.message_id, text: text]
    |> Keyword.merge(opts)
    |> Keyword.put(:token, Settings.telegram_token())
    |> ExGram.edit_message_text()
    |> case do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)
end
