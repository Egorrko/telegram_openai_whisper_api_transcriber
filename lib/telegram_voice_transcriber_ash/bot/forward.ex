defmodule TelegramVoiceTranscriberAsh.Bot.Forward do
  @moduledoc """
  Scenario 3.5: voice, audio and video notes from `FORWARD_CHAT_IDS` chats are
  forwarded to the operator, annotated with who sent them where, and
  transcribed there.

  The transcript is attached to the operator's copy while the quota is charged
  to the original sender — that asymmetry is deliberate and matches the source.
  As in the source, a failure here is reported and never surfaces in the chat
  the message came from: nobody there asked for a forward.
  """

  require Logger

  alias TelegramVoiceTranscriberAsh.Bot.Identity
  alias TelegramVoiceTranscriberAsh.Bot.Media
  alias TelegramVoiceTranscriberAsh.Bot.Pipeline
  alias TelegramVoiceTranscriberAsh.Settings

  @spec run(ExGram.Model.Message.t()) :: :ok
  def run(message) do
    with admin_id when not is_nil(admin_id) <- Settings.admin_id(),
         %{} = media <- Media.from(message) do
      forward(message, media, admin_id)
    end

    :ok
  rescue
    exception ->
      Sentry.capture_exception(exception, stacktrace: __STACKTRACE__)
      Logger.warning("forwarding to the operator failed: #{Exception.message(exception)}")
      :ok
  end

  defp forward(message, media, admin_id) do
    {:ok, forwarded} =
      ExGram.forward_message(admin_id, message.chat.id, message.message_id, token: token())

    ExGram.send_message(admin_id, source_info(message),
      reply_parameters: %ExGram.Model.ReplyParameters{message_id: forwarded.message_id},
      token: token()
    )

    Pipeline.run(forwarded, media, hashed_user_id: Identity.hash(message.from.id))
  end

  defp source_info(message) do
    """
    From: #{message.chat.title} (@#{message.chat.username || message.chat.id || "no username"})
    User: #{full_name(message.from) || message.from.id || "no username"}\
    """
  end

  defp full_name(%{first_name: first, last_name: last}) do
    [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") |> presence()
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp token, do: Settings.telegram_token()
end
