import io

from abc import ABC, abstractmethod

from config import settings


class TranscriptionService(ABC):
    @abstractmethod
    def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        pass


class OpenAIWhisperTS(TranscriptionService):
    def __init__(self):
        from openai import AsyncOpenAI

        if settings.OPENAI_API_KEY is None:
            raise ValueError("Для OpenAI необходимо установить OPENAI_API_KEY")
        self.client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        file_tuple = ("file", file_data.getvalue(), mime_type)
        transcript = await self.client.audio.transcriptions.create(
            model="whisper-1", file=file_tuple, response_format="text"
        )
        return transcript


class OpenAIGPT4oMiniTranscribeTS(TranscriptionService):
    def __init__(self):
        from openai import AsyncOpenAI

        if settings.OPENAI_API_KEY is None:
            raise ValueError("Для OpenAI необходимо установить OPENAI_API_KEY")
        self.client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        file_tuple = ("file", file_data.getvalue(), mime_type)
        transcript = await self.client.audio.transcriptions.create(
            model="gpt-4o-mini-transcribe", file=file_tuple, response_format="text"
        )
        return transcript


class ElevenLabsScribeV1TS(TranscriptionService):
    def __init__(self):
        from elevenlabs.client import AsyncElevenLabs

        api_key = settings.ELEVENLABS_API_KEY
        if api_key is None:
            raise ValueError("Для ElevenLabs необходимо установить ELEVENLABS_API_KEY")
        self.client = AsyncElevenLabs(api_key=api_key)

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        response = await self.client.speech_to_text.convert(
            file=file_data, model_id="scribe_v1"
        )
        return response.text or "..."


class ElevenLabsScribeV2TS(TranscriptionService):
    def __init__(self):
        from elevenlabs.client import AsyncElevenLabs

        api_key = settings.ELEVENLABS_API_KEY
        if api_key is None:
            raise ValueError("Для ElevenLabs необходимо установить ELEVENLABS_API_KEY")
        self.client = AsyncElevenLabs(api_key=api_key)

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        response = await self.client.speech_to_text.convert(
            file=file_data, model_id="scribe_v2"
        )
        return response.text or "..."


class Gemini25FlashTranscribeTS(TranscriptionService):
    def __init__(self):
        from google import genai

        api_key = settings.GEMINI_API_KEY
        if api_key is None:
            raise ValueError("Для Gemini необходимо установить GEMINI_API_KEY")

        self.client = genai.Client()

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        from google.genai.types import GenerateContentConfig, UploadFileConfig

        file = await self.client.aio.files.upload(
            file=file_data, config=UploadFileConfig(mime_type=mime_type)
        )
        prompt = settings.GEMINI_PROMPT
        response = await self.client.aio.models.generate_content(
            model="gemini-2.5-flash",
            contents=[prompt, file],
            config=GenerateContentConfig(response_mime_type="application/json"),
        )
        if not response.text:
            raise Exception(response)
        return response.text


class Gemini3FlashTranscribeTS(TranscriptionService):
    def __init__(self):
        from google import genai

        api_key = settings.GEMINI_API_KEY
        if api_key is None:
            raise ValueError("Для Gemini необходимо установить GEMINI_API_KEY")

        self.client = genai.Client()

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        from google.genai.types import GenerateContentConfig, UploadFileConfig

        file = await self.client.aio.files.upload(
            file=file_data, config=UploadFileConfig(mime_type=mime_type)
        )
        prompt = settings.GEMINI_PROMPT
        response = await self.client.aio.models.generate_content(
            model="gemini-3-flash-preview",
            contents=[prompt, file],
            config=GenerateContentConfig(response_mime_type="application/json"),
        )
        if not response.text:
            raise Exception(response)
        return response.text


class Gemini25FlashLiteTranscribeTS(TranscriptionService):
    def __init__(self):
        from google import genai

        api_key = settings.GEMINI_API_KEY
        if api_key is None:
            raise ValueError("Для Gemini необходимо установить GEMINI_API_KEY")

        self.client = genai.Client()

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        from google.genai.types import GenerateContentConfig, UploadFileConfig

        file = await self.client.aio.files.upload(
            file=file_data, config=UploadFileConfig(mime_type=mime_type)
        )
        prompt = settings.GEMINI_PROMPT
        response = await self.client.aio.models.generate_content(
            model="gemini-2.5-flash-lite",
            contents=[prompt, file],
            config=GenerateContentConfig(response_mime_type="application/json"),
        )
        if not response.text:
            raise Exception(response)
        return response.text


class Gemini31FlashLiteTranscribeTS(TranscriptionService):
    def __init__(self):
        from google import genai

        api_key = settings.GEMINI_API_KEY
        if api_key is None:
            raise ValueError("Для Gemini необходимо установить GEMINI_API_KEY")

        self.client = genai.Client()

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        from google.genai.types import GenerateContentConfig, UploadFileConfig

        file = await self.client.aio.files.upload(
            file=file_data, config=UploadFileConfig(mime_type=mime_type)
        )
        prompt = settings.GEMINI_PROMPT
        response = await self.client.aio.models.generate_content(
            model="gemini-3.1-flash-lite",
            contents=[prompt, file],
            config=GenerateContentConfig(response_mime_type="application/json"),
        )
        if not response.text:
            raise Exception(response)
        return response.text


class Gemini35FlashLiteTranscribeTS(TranscriptionService):
    def __init__(self):
        from google import genai

        api_key = settings.GEMINI_API_KEY
        if api_key is None:
            raise ValueError("Для Gemini необходимо установить GEMINI_API_KEY")

        self.client = genai.Client()

    async def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        from google.genai.types import GenerateContentConfig, UploadFileConfig

        file = await self.client.aio.files.upload(
            file=file_data, config=UploadFileConfig(mime_type=mime_type)
        )
        prompt = settings.GEMINI_PROMPT
        response = await self.client.aio.models.generate_content(
            model="gemini-3.5-flash-lite",
            contents=[prompt, file],
            config=GenerateContentConfig(response_mime_type="application/json"),
        )
        if not response.text:
            raise Exception(response)
        return response.text


def get_transcription_client(engine_name: str) -> TranscriptionService:
    engines = {
        "openai-whisper": OpenAIWhisperTS(),
        "openai-gpt-4o-mini-transcribe": OpenAIGPT4oMiniTranscribeTS(),
        "elevenlabs-scribe_v1": ElevenLabsScribeV1TS(),
        "elevenlabs-scribe_v2": ElevenLabsScribeV2TS(),
        "gemini-2.5-flash": Gemini25FlashTranscribeTS(),
        "gemini-3-flash-preview": Gemini3FlashTranscribeTS(),
        "gemini-2.5-flash-lite": Gemini25FlashLiteTranscribeTS(),
        "gemini-3.1-flash-lite": Gemini31FlashLiteTranscribeTS(),
        "gemini-3.5-flash-lite": Gemini35FlashLiteTranscribeTS(),
    }
    if engine_name not in engines:
        raise ValueError(
            f"Invalid engine name: {engine_name}. Available engines: {engines.keys()}"
        )
    return engines[engine_name]


transcription_client = get_transcription_client(settings.TRANSCRIPTION_ENGINE)
if settings.FALLBACK_TRANSCRIPTION_ENGINE:
    fallback_transcription_client = get_transcription_client(
        settings.FALLBACK_TRANSCRIPTION_ENGINE
    )
else:
    fallback_transcription_client = None
