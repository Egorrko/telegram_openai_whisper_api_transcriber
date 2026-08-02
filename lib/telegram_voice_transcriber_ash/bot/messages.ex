defmodule TelegramVoiceTranscriberAsh.Bot.Messages do
  @moduledoc """
  User-facing copy, ported verbatim from `src/bot/messages.py`. Minutes are
  always rounded up, as in the source.
  """

  alias TelegramVoiceTranscriberAsh.Metering.Subscriber
  alias TelegramVoiceTranscriberAsh.Settings

  @reset_after_days 30

  def start do
    """

    Привет! Я распознаю голосовые сообщения. Вы кидаете мне голосовое, я в ответ возвращаю его текстовую версию.

    Ещё мне можно прислать голосовую заметку из встроенного приложения айфона.

    Распознавание занимает от пары секунд до пары десятков секунд, в зависимости от длины аудио.

    Ничего не записываю и не храню.

    Каждый месяц тебе доступно #{minutes(Settings.available_seconds())} минут на распознавание.

    Полезные команды:
    /stats - проверить, сколько минут осталось.
    /payment N - купить дополнительные минуты.
    """
  end

  def stats(%Subscriber{} = subscriber) do
    next_reset =
      subscriber.last_free_reset_at
      |> DateTime.add(@reset_after_days, :day)
      |> Calendar.strftime("%d.%m.%Y")

    """

    Баланс минут:
    Бесплатные: #{minutes(subscriber.left_free_seconds)}
    Купленные: #{minutes(subscriber.left_purchased_seconds)}

    Твои бесплатные минуты обновятся #{next_reset}.
    """
  end

  # The source labels the remaining balance "Использовано" in both messages
  # below. Kept as-is: it is user-visible copy, not a rule. See defect D6.
  def limit_exceeded(%Subscriber{} = subscriber) do
    """

    На этот месяц бесплатные минуты закончились.

    Использовано: #{minutes(total(subscriber))}/#{minutes(Settings.available_seconds())} минут.

    Ты можешь приобрести дополнительные минуты командой /payment N.
    """
  end

  def limit_warning(%Subscriber{} = subscriber) do
    """

    У тебя заканчиваются бесплатные минуты.

    Использовано: #{minutes(total(subscriber))}/#{minutes(Settings.available_seconds())} минут.
    """
  end

  defp total(subscriber), do: subscriber.left_free_seconds + subscriber.left_purchased_seconds

  defp minutes(seconds), do: ceil(seconds / 60)
end
