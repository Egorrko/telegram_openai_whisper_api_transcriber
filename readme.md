# telegram_openai_whisper_api_transcriber

Telegram bot to transcribe voice messages using OpenAI Whisper API

## Installation

pip3 install -r requirements.txt
sudo apt install libmagic1

## Running

TELEGRAM_TOKEN='your telegram token here' OPENAI_API_KEY='your openai api key here' python3 goodsecretarybot.py

## Using Docker compose (recommended way)

Added local telegram-bot-api service for handling files larger than 20MB.

1. `cp .env.example .env` and fill .env file with correct variables.
2. `touch transcriptions.db` - create empty database file.
3. `./logout.sh` - [logout](https://github.com/tdlib/telegram-bot-api#moving-a-bot-to-a-local-server) from telegram bot api server.
4. `docker compose up -d`
