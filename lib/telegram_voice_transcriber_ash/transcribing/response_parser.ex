defmodule TelegramVoiceTranscriberAsh.Transcribing.ResponseParser do
  @moduledoc """
  Splits an engine answer into a short summary and the full transcript.

  Gemini engines return `{"short": ..., "full": ...}` JSON; the other engines
  return plain text. Malformed JSON is salvaged field by field so the user
  never sees raw JSON scaffolding (R14).

  Port of `parse_transcription_response` in
  `src/bot/services/file_processor.py`.
  """

  @summary_max_length 80
  @full_pattern ~r/"full"\s*:\s*"((?:[^"\\]|\\.)*)/s

  @type result :: %{short: String.t() | nil, full: String.t()}

  @spec parse(String.t()) :: result()
  def parse(text) do
    stripped = String.trim(text)

    with nil <- parse_json(stripped),
         nil <- salvage(stripped) do
      %{short: nil, full: stripped}
    end
  end

  defp parse_json(text) do
    with {:ok, %{"full" => full} = data} when is_binary(full) <- decode(text),
         trimmed when trimmed != "" <- String.trim(full) do
      %{short: short(data), full: trimmed}
    else
      _ -> nil
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> decode_embedded(text)
    end
  end

  # The model sometimes wraps the object in prose. Take the outermost braces.
  defp decode_embedded(text) do
    first = :binary.match(text, "{")
    last = last_brace(text)

    case {first, last} do
      {{start, _}, stop} when is_integer(stop) and stop > start ->
        text |> binary_part(start, stop - start + 1) |> Jason.decode()

      _ ->
        :error
    end
  end

  defp last_brace(text) do
    case :binary.matches(text, "}") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp short(%{"short" => short}) when is_binary(short) do
    short
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @summary_max_length)
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp short(_), do: nil

  # Invalid JSON that still clearly carries a "full" field: rescue the field
  # and tell Sentry, rather than showing the user a broken object.
  defp salvage("{" <> _ = text) do
    with true <- String.contains?(text, ~s("full")),
         [_, captured] <- Regex.run(@full_pattern, text),
         full when full != "" <- unescape(captured) do
      Sentry.capture_message("Malformed transcription JSON, salvaging 'full' field")
      %{short: nil, full: full}
    else
      _ -> nil
    end
  end

  defp salvage(_), do: nil

  # The model may emit raw control characters inside JSON string values, which
  # is invalid JSON. A stray backslash before a control character is collapsed
  # first, then bare controls are escaped so the value can be decoded.
  defp unescape(value) do
    value
    |> String.replace(~r/\\([\x00-\x1f])/, "\\1")
    |> escape_controls()
    |> then(&Jason.decode(~s("#{&1}")))
    |> case do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp escape_controls(value) do
    String.replace(value, ~r/[\x00-\x1f]/, fn <<char>> ->
      "\\u" <> Base.encode16(<<0, char>>, case: :lower)
    end)
  end
end
