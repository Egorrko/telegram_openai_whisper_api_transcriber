import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from bot.services.file_processor import ProcessStatus, send_results
from config import settings

pytestmark = pytest.mark.asyncio


def _make_message_and_msg():
    message = MagicMock()
    message.chat.id = 111
    message.as_reply_parameters.return_value = "reply_params_stub"
    msg = MagicMock()
    msg.chat.id = 111
    msg.message_id = 42
    return message, msg


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


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_short_transcription_rich_message(mock_bot):
    """Short transcript: one edit_message_text with Rich Message details block."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    transcript = "Привет, мир! Это короткая транскрипция."

    await send_results(message, msg, transcript, set_step)

    set_step.assert_awaited_once_with(msg, ProcessStatus.SENDING, notify_user=False)

    mock_bot.edit_message_text.assert_awaited_once()
    edit_kwargs = mock_bot.edit_message_text.call_args.kwargs
    assert edit_kwargs["chat_id"] == msg.chat.id
    assert edit_kwargs["message_id"] == msg.message_id

    rich = edit_kwargs["rich_message"]
    details = _extract_details(rich)
    assert details.summary == "📝 Транскрипция"
    assert details.is_open is None
    assert _extract_paragraph_text(details) == transcript

    mock_bot.send_rich_message.assert_not_awaited()


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_exact_boundary_single_message(mock_bot):
    """Transcript of exactly MAX_RICH_MESSAGE_LENGTH: one edit, no overflow."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    limit = settings.MAX_RICH_MESSAGE_LENGTH
    transcript = "a" * limit

    await send_results(message, msg, transcript, set_step)

    mock_bot.edit_message_text.assert_awaited_once()
    rich = mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    details = _extract_details(rich)
    assert _extract_paragraph_text(details) == transcript

    mock_bot.send_rich_message.assert_not_awaited()


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_overflow_multi_chunk(mock_bot):
    """Transcript spanning 3 chunks: one edit + two send_rich_message calls."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    limit = settings.MAX_RICH_MESSAGE_LENGTH
    transcript = "x" * limit + "y" * limit + "z" * 100

    await send_results(message, msg, transcript, set_step)

    # First chunk: in-place edit
    mock_bot.edit_message_text.assert_awaited_once()
    edit_rich = mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    edit_details = _extract_details(edit_rich)
    assert _extract_paragraph_text(edit_details) == "x" * limit

    # Overflow chunks: send_rich_message
    assert mock_bot.send_rich_message.await_count == 2

    first_send = mock_bot.send_rich_message.call_args_list[0].kwargs
    second_send = mock_bot.send_rich_message.call_args_list[1].kwargs

    first_details = _extract_details(first_send["rich_message"])
    second_details = _extract_details(second_send["rich_message"])

    assert _extract_paragraph_text(first_details) == "y" * limit
    assert _extract_paragraph_text(second_details) == "z" * 100

    # All overflow messages reply to the original message
    assert first_send["chat_id"] == message.chat.id
    assert second_send["chat_id"] == message.chat.id
    assert first_send["reply_parameters"] == "reply_params_stub"
    assert second_send["reply_parameters"] == "reply_params_stub"

    # Reconstruction
    reconstructed = (
        _extract_paragraph_text(edit_details)
        + _extract_paragraph_text(first_details)
        + _extract_paragraph_text(second_details)
    )
    assert reconstructed == transcript


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_overflow_boundary_plus_one(mock_bot):
    """Transcript of MAX_RICH_MESSAGE_LENGTH + 1: exactly two messages."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    limit = settings.MAX_RICH_MESSAGE_LENGTH
    transcript = "b" * (limit + 1)

    await send_results(message, msg, transcript, set_step)

    mock_bot.edit_message_text.assert_awaited_once()
    assert mock_bot.send_rich_message.await_count == 1

    edit_rich = mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    send_rich = mock_bot.send_rich_message.call_args.kwargs["rich_message"]

    edit_text = _extract_paragraph_text(_extract_details(edit_rich))
    send_text = _extract_paragraph_text(_extract_details(send_rich))

    assert edit_text == "b" * limit
    assert send_text == "b"
    assert edit_text + send_text == transcript


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_unicode_boundary(mock_bot):
    """Cyrillic and emoji across chunk boundary: exact reconstruction."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    limit = settings.MAX_RICH_MESSAGE_LENGTH

    # Place multibyte chars right at the boundary
    prefix = "а" * (limit - 2)  # 2 chars before boundary
    boundary_chars = "🎤т"  # emoji (4 bytes UTF-8) + Cyrillic (2 bytes)
    suffix = "б" * 50
    transcript = prefix + boundary_chars + suffix

    await send_results(message, msg, transcript, set_step)

    edit_rich = mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    edit_text = _extract_paragraph_text(_extract_details(edit_rich))
    assert edit_text == transcript[:limit]

    assert mock_bot.send_rich_message.await_count == 1
    send_rich = mock_bot.send_rich_message.call_args.kwargs["rich_message"]
    send_text = _extract_paragraph_text(_extract_details(send_rich))
    assert send_text == transcript[limit:]

    assert edit_text + send_text == transcript


@patch("bot.services.file_processor.bot", new_callable=AsyncMock)
async def test_all_chunks_within_rich_limit(mock_bot):
    """No chunk exceeds MAX_RICH_MESSAGE_LENGTH."""
    message, msg = _make_message_and_msg()
    set_step = AsyncMock()
    limit = settings.MAX_RICH_MESSAGE_LENGTH
    transcript = "d" * (limit * 3 + 500)

    await send_results(message, msg, transcript, set_step)

    all_texts = []
    edit_rich = mock_bot.edit_message_text.call_args.kwargs["rich_message"]
    all_texts.append(_extract_paragraph_text(_extract_details(edit_rich)))

    for call in mock_bot.send_rich_message.call_args_list:
        rich = call.kwargs["rich_message"]
        all_texts.append(_extract_paragraph_text(_extract_details(rich)))

    for text in all_texts:
        assert len(text) <= limit
    assert "".join(all_texts) == transcript


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

    transcript = "c" * 100
    await send_results(message, msg, transcript, tracking_set_step)

    assert call_order[0] == ("set_step", ProcessStatus.SENDING)
