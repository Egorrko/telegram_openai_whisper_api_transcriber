defmodule TelegramVoiceTranscriberAsh.Transcribing.RichMessageTest do
  @moduledoc "Port of the rendering half of `src/bot/tests/send_results_tests.py`."

  use ExUnit.Case, async: true

  alias TelegramVoiceTranscriberAsh.Transcribing.ResponseParser
  alias TelegramVoiceTranscriberAsh.Transcribing.RichMessage

  @max_rich_message_length 32_768

  defp render(short, full), do: RichMessage.render(%{short: short, full: full})

  describe "layout" do
    test "a short transcript becomes a block quotation" do
      assert {:quotation, "Привет, мир!"} = render("Привет", "Привет, мир!")
    end

    test "plain-text engine output is laid out the same way" do
      assert {:quotation, "Короткий ответ."} =
               "Короткий ответ." |> ResponseParser.parse() |> RichMessage.render()
    end

    test "the threshold is 200 characters, not line count" do
      assert {:quotation, _} = render(nil, String.duplicate("а", 200))
      assert {:details, _, _} = render(nil, String.duplicate("а", 201))
    end

    test "a long transcript becomes a details block with the model's summary" do
      full = "Первая строка.\n" <> String.duplicate("Вторая строка. ", 20) <> "Конец."

      assert {:details, "Коротко о встрече", [^full]} = render("Коротко о встрече", full)
    end

    test "a single long line is not truncated" do
      full = String.duplicate("а", 4097)

      assert {:details, _, [^full]} = render("Длинно", full)
    end
  end

  describe "summary (R12)" do
    test "falls back to the first line when the model gave no short answer" do
      full = "Заголовок\n" <> String.duplicate("тело сообщения ", 20)

      assert {:details, "Заголовок", _} = render(nil, full)
    end

    test "the first-line fallback is capped at 80 characters" do
      full = String.duplicate("а", 300) <> "\nхвост"

      assert {:details, summary, _} = render(nil, full)
      assert String.length(summary) == 80
    end

    test "falls back to a generic header when the first line is blank" do
      full = "\n" <> String.duplicate("тело сообщения ", 20)

      assert {:details, "📝 Транскрипция", _} = render(nil, full)
    end
  end

  describe "chunking (R13)" do
    test "chunk size accounts for the summary length and the text round-trips" do
      summary = "Суть"
      chunk_size = @max_rich_message_length - String.length(summary)
      full = String.duplicate("x", chunk_size) <> "\n" <> String.duplicate("y", chunk_size)

      assert {:details, ^summary, chunks} = render(summary, full)
      assert length(chunks) == 3
      assert Enum.join(chunks) == full

      for chunk <- chunks do
        assert String.length(chunk) + String.length(summary) <= @max_rich_message_length
      end
    end
  end

  describe "payload" do
    test "a block quotation carries one paragraph" do
      payload = RichMessage.payload({:quotation, "Привет"})

      assert %{blocks: [%{type: "blockquote", blocks: [%{type: "paragraph", text: "Привет"}]}]} =
               payload

      assert %ExGram.Model.InputRichMessage{} = payload
    end

    test "a details block carries the summary and one paragraph" do
      assert %{blocks: [%{type: "details", summary: "Суть", blocks: [paragraph]}]} =
               RichMessage.payload({:details, "Суть", "тело"})

      assert %{type: "paragraph", text: "тело"} = paragraph
    end
  end
end
