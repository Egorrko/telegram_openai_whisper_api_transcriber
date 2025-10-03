from abc import ABC, abstractmethod
import io
import os

class TranscriptionService(ABC):
    @abstractmethod
    def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        pass


class OpenAIWhisperTS(TranscriptionService):
    def __init__(self):
        from openai import OpenAI
        if not os.getenv('OPENAI_API_KEY'):
            raise ValueError("Для OpenAI необходимо установить OPENAI_API_KEY")
        self.client = OpenAI()

    def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        file_tuple = ('file', file_data.getvalue(), mime_type)
        transcript = self.client.audio.transcriptions.create(
            model="whisper-1",
            file=file_tuple,
            response_format="text"
        )
        return transcript


class OpenAIGPT4oMiniTranscribeTS(TranscriptionService):
    def __init__(self):
        from openai import OpenAI
        if not os.getenv('OPENAI_API_KEY'):
            raise ValueError("Для OpenAI необходимо установить OPENAI_API_KEY")
        self.client = OpenAI()

    def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        file_tuple = ('file', file_data.getvalue(), mime_type)
        transcript = self.client.audio.transcriptions.create(
            model="gpt-4o-mini-transcribe",
            file=file_tuple,
            response_format="text"
        )
        return transcript


class ElevenLabsScribeV1TS(TranscriptionService):
    def __init__(self):
        from elevenlabs import ElevenLabs
        api_key = os.environ.get('ELEVENLABS_API_KEY')
        if not api_key:
            raise ValueError("Для ElevenLabs необходимо установить ELEVENLABS_API_KEY")
        self.client = ElevenLabs(api_key=api_key)

    def transcribe(self, file_data: io.BytesIO, mime_type: str) -> str:
        response = self.client.speech_to_text.convert(
            file=file_data,
            model_id="scribe_v1"
        )
        return response.text


def get_transcription_client(engine_name: str) -> TranscriptionService:
    if engine_name == 'openai-whisper':
        print("Using OpenAI Whisper transcription engine.")
        return OpenAIWhisperTS()
    elif engine_name == 'openai-gpt-4o-mini-transcribe':
        print("Using OpenAI GPT-4o Mini transcription engine.")
        return OpenAIGPT4oMiniTranscribeTS()
    elif engine_name == 'elevenlabs-scribe_v1':
        print("Using ElevenLabs transcription engine.")
        return ElevenLabsScribeV1TS()
    else:
        raise ValueError(f"Неизвестный движок транскрибации: {engine_name}")
