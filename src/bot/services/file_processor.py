import asyncio
import tempfile
import sentry_sdk
import os
import subprocess
import io
import json
import re

from enum import StrEnum
from dataclasses import dataclass
from aiogram.utils.formatting import BlockQuote, Pre
from aiogram.types import (
    InputRichMessage,
    InputRichBlockDetails,
    InputRichBlockParagraph,
)
from bot.bot_init import bot
from config import settings
import bot.messages as messages
from bot.services.transcribe import transcription_client, fallback_transcription_client
from bot.services import db
import time


class ProcessStatus(StrEnum):
    INIT = "Инициализация"
    DOWNLOAD = "Скачиваю файл..."
    CONVERT = "Достаю звук из видео..."
    TRANSCRIBE = "Распознаю..."
    SENDING = "Отправляю результат..."


async def convert_video_to_audio(file):
    with tempfile.NamedTemporaryFile() as temp_file:
        temp_file.write(file.read())
        file_path = temp_file.name

        command = ["ffmpeg", "-i", file_path, "-vn", "-c:a", "copy", "-f", "adts", "-"]
        process = await asyncio.create_subprocess_exec(
            *command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        audio_bytes, stderr_bytes = await process.communicate()

        if process.returncode != 0:
            raise Exception(f"{stderr_bytes.decode()}")

        return io.BytesIO(audio_bytes), "audio/aac"


async def check_user_limits(message, hashed_user_id, file_duration):
    user, check_result = await db.prepare_user_for_transcription(
        hashed_user_id, file_duration
    )
    if check_result == "exceeded":
        await message.reply(
            messages.limit_exceeded_message(
                user.left_free_seconds + user.left_purchased_seconds,
                settings.AVAILABLE_SECONDS,
            )
        )
        return user, False
    elif check_result == "show_warning":
        await message.reply(
            messages.limit_warning_message(
                user.left_free_seconds + user.left_purchased_seconds,
                settings.AVAILABLE_SECONDS,
            )
        )
    return user, True


async def download_and_prep_file(msg, file_id, file_type, mime_type, set_step):
    await set_step(msg, ProcessStatus.DOWNLOAD)
    file_info = await bot.get_file(file_id)
    file = await bot.download_file(file_info.file_path, timeout=60)

    if file_type == "video_note":
        await set_step(msg, ProcessStatus.CONVERT)
        audio_bytes, new_mime_type = await convert_video_to_audio(file)
        return file_info, audio_bytes, new_mime_type

    return file_info, file, mime_type


async def run_transcription(msg, audio_bytes, mime_type, set_step):
    retries = 0
    start_time = time.time()
    transcript = None
    errors = []

    await set_step(msg, ProcessStatus.TRANSCRIBE)
    while retries < settings.MAX_RETRIES:
        try:
            transcript = await transcription_client.transcribe(audio_bytes, mime_type)
            return transcript, time.time() - start_time
        except Exception as e:
            audio_bytes.seek(0)
            retries += 1
            await msg.edit_text(
                **BlockQuote(
                    f"Попытка {retries}/{settings.MAX_RETRIES}...\nЖдите {(settings.RETRY_DELAY * retries)} секунд..."
                ).as_kwargs()
            )
            await asyncio.sleep((settings.RETRY_DELAY * retries))
            if retries == settings.MAX_RETRIES:
                errors.append(e)

    if transcript is None and fallback_transcription_client:
        try:
            await msg.edit_text(**BlockQuote("Последняя попытка...").as_kwargs())
            audio_bytes.seek(0)
            transcript = await fallback_transcription_client.transcribe(
                audio_bytes, mime_type
            )
            return transcript, time.time() - start_time
        except Exception as e:
            errors.append(e)

    if transcript is None:
        error_text = "\n\n".join([f"{type(e).__name__}: {str(e)}" for e in errors])
        raise Exception(error_text)


TRANSCRIPTION_SUMMARY = "📝 Транскрипция"
SHORT_SUMMARY_MAX_LENGTH = 80
PLAIN_TEXT_MAX_LENGTH = 200
_JSON_FULL_PATTERN = re.compile(r'"full"\s*:\s*"((?:[^"\\]|\\.)*)', re.DOTALL)


@dataclass(frozen=True)
class TranscriptionResult:
    short: str | None
    full: str


def _unescape_json_string(value: str) -> str:
    # The model may emit raw control characters (newlines, tabs) inside JSON
    # string values, which is invalid JSON. A stray backslash before a control
    # character is collapsed first, then bare controls are escaped for decoding.
    value = re.sub(r"\\([\x00-\x1f])", r"\1", value)
    escaped = re.sub(r"[\x00-\x1f]", lambda m: "\\u%04x" % ord(m.group()), value)
    try:
        return json.loads(f'"{escaped}"')
    except ValueError:
        return value


def _extract_full_from_malformed_json(text: str) -> str | None:
    match = _JSON_FULL_PATTERN.search(text)
    if match is None:
        return None
    return _unescape_json_string(match.group(1))


def _try_parse_transcription_json(text: str) -> TranscriptionResult | None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        first_brace = text.find("{")
        last_brace = text.rfind("}")
        if first_brace == -1 or last_brace <= first_brace:
            return None
        try:
            data = json.loads(text[first_brace : last_brace + 1])
        except json.JSONDecodeError:
            return None

    if not isinstance(data, dict) or not isinstance(data.get("full"), str):
        return None

    full = data["full"].strip()
    if not full:
        return None

    short = data.get("short")
    if not isinstance(short, str):
        short = None
    else:
        short = " ".join(short.split())[:SHORT_SUMMARY_MAX_LENGTH].strip() or None

    return TranscriptionResult(short=short, full=full)


def parse_transcription_response(text: str) -> TranscriptionResult:
    """Split the model answer into a short summary and the full transcript.

    Gemini engines return JSON {"short": ..., "full": ...}; other engines
    return plain text. Malformed JSON is salvaged field-by-field so the user
    never sees raw JSON scaffolding.
    """
    stripped = text.strip()
    result = _try_parse_transcription_json(stripped)
    if result is not None:
        return result

    if stripped.startswith("{") and '"full"' in stripped:
        sentry_sdk.capture_message(
            "Malformed transcription JSON, salvaging 'full' field"
        )
        full = _extract_full_from_malformed_json(stripped)
        if full:
            return TranscriptionResult(short=None, full=full)

    return TranscriptionResult(short=None, full=stripped)


def _first_line(text: str) -> str:
    return text.split("\n", 1)[0].strip()


def _build_rich_message(summary: str, text: str) -> InputRichMessage:
    return InputRichMessage(
        blocks=[
            InputRichBlockDetails(
                summary=summary,
                blocks=[InputRichBlockParagraph(text=text)],
            )
        ]
    )


async def send_results(message, msg, transcript, set_step):
    await set_step(msg, ProcessStatus.SENDING, notify_user=False)

    result = parse_transcription_response(transcript)
    full = result.full

    # Short answers are shown as plain text; longer ones go into a collapsible
    # block with the short summary as its header.
    if len(full) <= PLAIN_TEXT_MAX_LENGTH:
        await msg.edit_text(full)
        return

    summary = result.short or _first_line(full)[:SHORT_SUMMARY_MAX_LENGTH]
    summary = summary or TRANSCRIPTION_SUMMARY
    chunk_size = settings.MAX_RICH_MESSAGE_LENGTH - len(summary)
    chunks = [full[i : i + chunk_size] for i in range(0, len(full), chunk_size)]

    await bot.edit_message_text(
        chat_id=msg.chat.id,
        message_id=msg.message_id,
        rich_message=_build_rich_message(summary, chunks[0]),
    )

    for chunk in chunks[1:]:
        await bot.send_rich_message(
            chat_id=message.chat.id,
            rich_message=_build_rich_message(summary, chunk),
            reply_parameters=message.as_reply_parameters(),
        )


async def handle_file(
    message, hashed_user_id, file_type, file_duration, file_id, mime_type
):
    file_info = None

    current_step = ProcessStatus.INIT.name

    async def set_step(msg, step: ProcessStatus, notify_user=True):
        nonlocal current_step
        current_step = step.name
        if notify_user:
            try:
                await msg.edit_text(step.value)
            except Exception:
                pass

    msg = None
    try:
        user, should_continue = await check_user_limits(
            message, hashed_user_id, file_duration
        )
        if not should_continue:
            return

        msg = await message.reply("Распознаю...")

        file_info, audio_bytes, mime_type = await download_and_prep_file(
            msg, file_id, file_type, mime_type, set_step
        )

        transcript, transcription_time = await run_transcription(
            msg, audio_bytes, mime_type, set_step
        )

        await send_results(message, msg, transcript, set_step)

        await db.process_user_transcription(user, file_duration, transcription_time)
        await db.insert_transcription_log(user, file_duration, transcription_time)
    except Exception as e:
        error_text = str(e) if str(e) else f"{type(e).__name__}"

        if msg:
            await msg.edit_text(
                **Pre(
                    f"Ошибочка ({current_step}):\n{error_text}"[
                        : settings.MAX_MESSAGE_LENGTH
                    ]
                ).as_kwargs()
            )
        else:
            # Fallback if msg wasn't created yet
            await message.reply(
                **Pre(
                    f"Ошибочка ({current_step}):\n{error_text}"[
                        : settings.MAX_MESSAGE_LENGTH
                    ]
                ).as_kwargs()
            )

        sentry_sdk.set_context("pipeline", {"step": current_step})
        sentry_sdk.capture_exception(e)
        user, _ = await db.get_or_create_user(hashed_user_id)
        await db.insert_transcription_log(user, file_duration, -1)
    finally:
        if file_info and os.path.exists(file_info.file_path):
            os.remove(file_info.file_path)
