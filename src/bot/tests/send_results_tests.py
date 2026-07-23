import json

import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from bot.services.file_processor import (
    ProcessStatus,
    parse_transcription_response,
    send_results,
)
from config import settings


def _make_message_and_msg():
    message = MagicMock()
    message.chat.id = 111
    message.as_reply_parameters.return_value = "reply_params_stub"
    msg = MagicMock()
    msg.chat.id = 111
    msg.message_id = 42
    msg.edit_text = AsyncMock()
    return message, msg


def _json_response(short, full):
    return json.dumps({"short": short, "full": full}, ensure_ascii=False)


def _extract_details(rich_message):
    """Extract the single InputRichBlockDetails from an InputRichMessage."""
    assert len(rich_message.blocks) == 1
    details = rich_message.blocks[0]
    assert details.type == "details"
    return details


def _extract_paragraph_text(details):
    """Extract text from the single paragraph inside a details block."""
    assert len(details.blocks) == 1
    paragraph = details.blocks[0]
    assert paragraph.type == "paragraph"
    return paragraph.text


def _total_rich_text_length(rich_message):
    """Total text length of a rich message (summary + all paragraph texts)."""
    total = 0
    for block in rich_message.blocks:
        total += len(block.summary)
        for inner in block.blocks:
            total += len(inner.text)
    return total


# --- parse_transcription_response -------------------------------------------


def test_parse_valid_json():
    result = parse_transcription_response(_json_response("Суть", "полный\nтекст"))
    assert result.short == "Суть"
    assert result.full == "полный\nтекст"


def test_parse_json_with_surrounding_text():
    raw = "Вот результат:\n" + _json_response("Суть", "текст") + "\nГотово."
    result = parse_transcription_response(raw)
    assert result.short == "Суть"
    assert result.full == "текст"


def test_parse_malformed_json_with_literal_newlines():
    # Flash-lite models may emit raw newlines inside string values, which is
    # invalid JSON. The "full" field must still be salvaged.
    raw = '{"short": "Тест",\n"full": "абзац один\nабзац два"}'
    result = parse_transcription_response(raw)
    assert result.full == "абзац один\nабзац два"


def test_parse_malformed_json_backslash_before_newline():
    # A backslash immediately followed by a literal newline must not stop
    # the salvage capture early (re.DOTALL coverage).
    raw = '{"short": "Тест", "full": "первая \\\nвторая"}'
    result = parse_transcription_response(raw)
    assert result.full == "первая \nвторая"


def test_parse_plain_text_passthrough():
    result = parse_transcription_response("Просто текст\nв две строки")
    assert result.short is None
    assert result.full == "Просто текст\nв две строки"


def test_parse_json_escapes():
    raw = _json_response("Суть", 'строка с "кавычками" и \\обратным слэшем\\')
    result = parse_transcription_response(raw)
    assert result.full == 'строка с "кавычками" и \\обратным слэшем\\'


# --- send_results: plain text for one-line answers ---------------------------


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_json_single_line_full_plain_text(mock_bot):
    """One-line full answer: plain edit_text, no collapsible block."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()

    await send_results(message, msg, _json_response("Привет", "Привет, мир!"), set_step)

    msg.edit_text.assert_awaited_once_with("Привет, мир!")
    mock_bot.edit_message_text.assert_not_awaited()
    mock_bot.send_rich_message.assert_not_awaited()


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_plain_text_single_line_plain_text(mock_bot):
    """Non-JSON one-line transcript (other engines): plain edit_text."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()

    await send_results(message, msg, "Короткий ответ.", set_step)

    msg.edit_text.assert_awaited_once_with("Короткий ответ.")
    mock_bot.edit_message_text.assert_not_awaited()


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_long_single_line_uses_rich_message(mock_bot):
    """Single line longer than MAX_MESSAGE_LENGTH: rich message, not truncated."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    full = "а" * (settings.MAX_MESSAGE_LENGTH + 1)

    await send_results(message, msg, _json_response("Длинно", full), set_step)

    msg.edit_text.assert_not_awaited()
    mock_bot.edit_message_text.assert_awaited_once()
    details = _extract_details(
        mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    )
    assert _extract_paragraph_text(details) == full


# --- send_results: collapsible for multi-line answers ------------------------


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_json_multiline_collapsible_with_short_summary(mock_bot):
    """Multi-line full: collapsible details with the short answer as summary."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    full = "Первая строка.\nВторая строка."

    await send_results(
        message, msg, _json_response("Коротко о встрече", full), set_step
    )

    set_step.assert_awaited_once_with(msg, ProcessStatus.SENDING, notify_user=False)

    mock_bot.edit_message_text.assert_awaited_once()
    edit_kwargs = mock_bot.edit_message_text.call_args.kwargs
    assert edit_kwargs["chat_id"] == msg.chat.id
    assert edit_kwargs["message_id"] == msg.message_id

    details = _extract_details(edit_kwargs["rich_message"])
    assert details.summary == "Коротко о встрече"
    assert details.is_open is None
    assert _extract_paragraph_text(details) == full

    mock_bot.send_rich_message.assert_not_awaited()


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_plain_text_multiline_derived_summary(mock_bot):
    """Plain-text engine output: summary derived from the first line."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    transcript = "Первая строка\nВторая строка"

    await send_results(message, msg, transcript, set_step)

    details = _extract_details(
        mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    )
    assert details.summary == "Первая строка"
    assert _extract_paragraph_text(details) == transcript


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_missing_short_falls_back_to_first_line(mock_bot):
    """JSON without a usable short: summary derived from the first line."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    raw = json.dumps({"full": "Заголовок\nтело"}, ensure_ascii=False)

    await send_results(message, msg, raw, set_step)

    details = _extract_details(
        mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    )
    assert details.summary == "Заголовок"


# --- send_results: chunking ---------------------------------------------------


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_long_summary_chunks_within_rich_limit(mock_bot):
    """Chunk size accounts for the actual (long) summary length."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    summary = "Очень длинное краткое описание " * 3  # 93 chars -> capped to 80
    summary = summary.strip()[:80]
    chunk_size = settings.MAX_RICH_MESSAGE_LENGTH - len(summary)
    full = ("а" * (chunk_size - 1) + "\n") * 3 + "хвост"

    await send_results(message, msg, _json_response(summary, full), set_step)

    all_rich = [mock_bot.edit_message_text.call_args.kwargs["rich_message"]]
    all_rich += [
        c.kwargs["rich_message"] for c in mock_bot.send_rich_message.call_args_list
    ]

    reconstructed = []
    for rich in all_rich:
        assert _total_rich_text_length(rich) <= settings.MAX_RICH_MESSAGE_LENGTH
        details = _extract_details(rich)
        assert details.summary == summary
        reconstructed.append(_extract_paragraph_text(details))

    assert "".join(reconstructed) == full
    assert len(all_rich) == 4


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_overflow_multi_chunk_reconstruction(mock_bot):
    """Multi-chunk transcript: one edit + sends, exact reconstruction."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    summary = "Суть"
    chunk_size = settings.MAX_RICH_MESSAGE_LENGTH - len(summary)
    full = "x" * chunk_size + "\n" + "y" * chunk_size + "\n" + "z" * 100

    await send_results(message, msg, _json_response(summary, full), set_step)

    mock_bot.edit_message_text.assert_awaited_once()
    assert mock_bot.send_rich_message.await_count == 2

    for call in mock_bot.send_rich_message.call_args_list:
        assert call.kwargs["chat_id"] == message.chat.id
        assert call.kwargs["reply_parameters"] == "reply_params_stub"

    all_rich = [mock_bot.edit_message_text.call_args.kwargs["rich_message"]]
    all_rich += [
        c.kwargs["rich_message"] for c in mock_bot.send_rich_message.call_args_list
    ]
    reconstructed = "".join(
        _extract_paragraph_text(_extract_details(rich)) for rich in all_rich
    )
    assert reconstructed == full


@pytest.mark.asyncio
@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_sending_status_before_delivery(mock_bot):
    """set_step(SENDING) is called before any bot API call."""
    message, msg = _make_message_and_msg()
    call_order = []

    async def tracking_set_step(m, step, notify_user=True):
        call_order.append(("set_step", step))

    mock_bot.edit_message_text = AsyncMock(
        side_effect=lambda **kw: call_order.append(("edit_message_text",))
    )

    transcript = _json_response("Суть", "первая\nвторая")
    await send_results(message, msg, transcript, tracking_set_step)

    assert call_order[0] == ("set_step", ProcessStatus.SENDING)
