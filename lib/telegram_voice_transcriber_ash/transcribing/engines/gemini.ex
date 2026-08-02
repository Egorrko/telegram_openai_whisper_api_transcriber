defmodule TelegramVoiceTranscriberAsh.Transcribing.Engines.Gemini do
  @moduledoc """
  Google Gemini transcription. Returns the two-field
  `{"short": ..., "full": ...}` JSON contract described by `prompt/0`.

  The source uploaded every file to the Files API and never deleted it; this
  sends the audio inline instead, which is one request instead of two and
  leaves nothing behind.

  ponytail: inline audio caps a request at roughly 20 MB — the same limit the
  public Bot API imposes on downloads. Switch to the Files API if a local Bot
  API server starts feeding larger files through.
  """

  @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

  alias TelegramVoiceTranscriberAsh.Settings

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def transcribe(audio, mime_type, model) do
    with {:ok, api_key} <- api_key(),
         {:ok, %{status: 200, body: body}} <- post(api_key, model, audio, mime_type) do
      extract_text(body)
    else
      {:ok, %{status: status, body: body}} -> {:error, "Gemini HTTP #{status}: #{inspect(body)}"}
      {:error, _} = error -> error
    end
  end

  defp api_key do
    case Settings.gemini_api_key() do
      nil -> {:error, "Для Gemini необходимо установить GEMINI_API_KEY"}
      key -> {:ok, key}
    end
  end

  defp post(api_key, model, audio, mime_type) do
    Req.post(
      url: "#{@base_url}/#{model}:generateContent",
      headers: [{"x-goog-api-key", api_key}],
      json: %{
        contents: [
          %{
            parts: [
              %{text: prompt()},
              %{inline_data: %{mime_type: mime_type, data: Base.encode64(audio)}}
            ]
          }
        ],
        generationConfig: %{response_mime_type: "application/json"}
      },
      receive_timeout: 120_000
    )
  end

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join()
    |> case do
      "" -> {:error, "Gemini returned no text"}
      text -> {:ok, text}
    end
  end

  defp extract_text(body), do: {:error, "Gemini returned no candidates: #{inspect(body)}"}

  @doc """
  The transcription prompt. A product asset, ported verbatim from
  `GEMINI_PROMPT` in `src/config/settings.py`.
  """
  def prompt do
    """
    You are a precise transcription engine for Telegram voice messages.

    Your task is to convert the supplied audio into a faithful, natural, and easily readable transcript.

    TRANSCRIPTION

    Transcribe the speaker's words in the language in which they are spoken.

    Preserve the speaker's original manner of speech:

    * slang and informal expressions;
    * profanity;
    * meaningful filler words such as "ну", "короче", "типа", "вот";
    * repetitions;
    * unfinished phrases;
    * self-corrections;
    * switching between languages;
    * technical terms, names, and product names.

    Use natural punctuation and capitalization while preserving the original meaning and wording.

    When a fragment cannot be confidently understood, write:
    [неразборчиво]

    When the cause is clear, briefly specify it:
    [неразборчиво из-за шума]

    ACOUSTIC EVENTS

    Include a non-speech sound when it is clearly audible and meaningful for understanding the recording.

    Describe such sounds briefly in Russian inside square brackets and place the description where the sound occurs.

    Examples:
    [смеётся]
    [вздыхает]
    [кашляет]
    [звонок в дверь]
    [громкий сигнал]
    [лай собаки]
    [звук уведомления]
    [шум перекрывает речь]

    A continuous background sound is described once at the point where it becomes relevant.

    PAUSES

    Represent the natural rhythm of speech primarily through punctuation:

    * comma for a short hesitation;
    * ellipsis for a noticeable hesitation or unfinished thought;
    * paragraph break for a completed transition to another thought.

    Use [долгая пауза] for clearly extended silence that carries meaning, creates a strong emotional effect, or distinctly separates two parts of the message.

    PARAGRAPHS

    Format the transcript as natural written speech.

    Keep a short voice message in one paragraph.

    Create a new paragraph when the speaker:

    * moves to a new topic;
    * begins a separate argument or explanation;
    * transitions to another part of a story;
    * addresses a different person or question;
    * starts a clearly separate conclusion;
    * changes as part of a multi-speaker conversation.

    Keep closely related sentences and details together in the same paragraph.

    For longer messages, prefer several substantial paragraphs organized by meaning.

    MULTIPLE SPEAKERS

    For a single speaker, output the speech directly.

    For multiple clearly distinguishable speakers, use neutral labels:

    Говорящий 1:
    Говорящий 2:

    Place a label at each speaker change.

    EMOTION

    Preserve clearly audible emotion through punctuation, wording, and occasional emoji.

    Use an emoji only when the speaker's emotional reaction is unmistakable and the emoji adds useful meaning.

    Use no more than one emoji for a single emotional moment.

    Place the emoji after the relevant phrase.

    SPECIAL CASES

    For complete silence or audio containing only indistinct static, the "full" field must be exactly:

    [Тишина]

    For audio without speech but with a recognizable sound, the "full" field must be a concise description, e.g.:

    [Шум ветра и далёкий лай собаки]

    OUTPUT

    Respond with a single JSON object and nothing else:

    {"short": "<one-line summary>", "full": "<complete transcript>"}

    Rules for "short":
    * one line, up to 10 words;
    * the essence of the message, in the language of the speech;
    * no quotes, no trailing punctuation;
    * for silence or noise only: "Тишина" or a brief noise description.

    Rules for "full":
    * the complete transcript exactly as described in the sections above;
    * for complete silence: "[Тишина]".

    Do not wrap the JSON in markdown, code blocks, or comments.

    Input Audio:
    [Audio File]
    """
  end
end
