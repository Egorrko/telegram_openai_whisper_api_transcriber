defmodule TelegramVoiceTranscriberAsh.Transcribing.ResponseParserTest do
  @moduledoc "Port of the parsing half of `src/bot/tests/send_results_tests.py`."

  use ExUnit.Case, async: true

  alias TelegramVoiceTranscriberAsh.Transcribing.ResponseParser

  defp json(short, full), do: Jason.encode!(%{short: short, full: full})

  test "valid JSON" do
    assert %{short: "Суть", full: "полный\nтекст"} =
             ResponseParser.parse(json("Суть", "полный\nтекст"))
  end

  test "JSON wrapped in prose" do
    raw = "Вот результат:\n" <> json("Суть", "текст") <> "\nГотово."

    assert %{short: "Суть", full: "текст"} = ResponseParser.parse(raw)
  end

  test "malformed JSON with literal newlines still yields the full field" do
    # Flash-lite models emit raw newlines inside string values, which is
    # invalid JSON.
    raw = ~s({"short": "Тест",\n"full": "абзац один\nабзац два"})

    assert %{full: "абзац один\nабзац два"} = ResponseParser.parse(raw)
  end

  test "a backslash before a literal newline does not truncate the salvage" do
    raw = ~s({"short": "Тест", "full": "первая \\\nвторая"})

    assert %{full: "первая \nвторая"} = ResponseParser.parse(raw)
  end

  test "plain text passes through untouched" do
    assert %{short: nil, full: "Просто текст\nв две строки"} =
             ResponseParser.parse("Просто текст\nв две строки")
  end

  test "JSON escapes are decoded" do
    full = "строка с \"кавычками\" и \\обратным слэшем\\"

    assert %{full: ^full} = ResponseParser.parse(json("Суть", full))
  end

  test "a short longer than 80 characters is collapsed and truncated" do
    assert %{short: short} = ResponseParser.parse(json(String.duplicate("аб ", 40), "текст"))

    assert String.length(short) == 80
  end

  test "a blank full field is salvaged rather than shown as raw JSON" do
    assert %{short: nil, full: "   "} = ResponseParser.parse(json("Суть", "   "))
  end
end
