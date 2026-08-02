# telegram_voice_transciber replatforming analysis

## Bootstrap progress

Update this block as each item finishes. A resumed session continues from the
first unchecked item after confirming the recorded state against the filesystem.

- [x] 0. Toolchain checked
- [x] 1. Ecosystem catalog refreshed
- [x] 2. Source analysis — sections 1-10 below, each checked off in place
- [x] 3. Target dependencies selected and installer command built
- [x] 4. Target project created at: `/home/egorrko/code/elixir/tg_voice_showcase/telegram_voice_transcriber_ash`
- [x] 5. UsageRules and skills generated
- [x] 6. Bootstrap verified
- [x] 7. Target committed at revision: `498ece6`
- [x] 8. Analysis and handoff copied into the target and committed

Mark a completed analysis section by appending ` — done` to its heading.

## Analysis metadata

- Source repository: `/home/egorrko/code/elixir/tg_voice_showcase/telegram_voice_transciber`
- Source revision: `1f8d7d1` (Merge pull request #4 from Egorrko/feature/expandable-blockquote-transcription)
- Analysis date: 2026-08-02
- Toolchain versions and unavailable tools:
  - Elixir 1.20.2, Erlang/OTP 29 (erts-17.0.2)
  - Mix 1.20.2
  - Node v26.2.0, npm 11.16.0
  - git 2.43.0
  - Docker: available
  - PostgreSQL client: psql 17.10 available
  - No unavailable tools; every verification step in section 6 of the handoff is runnable.
- Ash ecosystem catalog generated at: 2026-08-02T13:38:56.713Z
- Ash HQ catalog commit: `d90e367d40ed33201cb4d1bb2ea23b9b7d7da458`
- Catalog age, refresh errors, or installer grammar drift: catalog was under 7 days old, refresh
  script reported "nothing to do". No refresh errors. No installer grammar drift reported.

## 1. Product purpose — done

A Telegram bot that converts voice messages, audio files and video notes into text.

The user sends a voice message to the bot in a private chat, in an allow-listed group, or
by replying to a voice message and mentioning the bot. The bot answers in the same thread
with a transcript, rendered as a Telegram rich message: a block quotation for short
transcripts, an expandable "details" block with a one-line summary header for longer ones
(`src/bot/services/file_processor.py:271-315`).

The product is metered. Every account gets a free monthly allowance of recognition time
(`AVAILABLE_MINUTES`, default 30), and can buy extra minutes with Telegram Stars
(`src/bot/handlers/payment.py`). Consumption is measured in seconds of source audio, not in
requests.

Privacy is an explicit product promise. The start message states "Ничего не записываю и не
храню" (`src/bot/messages.py:12`), and the data model holds this: the Telegram user ID is
stored only as a SHA-256 hash (`src/bot/handlers/voice.py:16`), and no audio or transcript
text is ever persisted — only duration and elapsed processing time
(`src/bot/models.py:24-31`).

There is a secondary operator capability: messages from configured `FORWARD_CHAT_IDS` groups
are forwarded to a single admin Telegram account, annotated with chat and sender, and
transcribed automatically (`src/bot/handlers/forward.py`).

Users: Telegram end users (private chats), members of allow-listed groups, and one operator
identified by `ADMIN_ID`.

## 2. Actors and roles — done

There is no web login anywhere in the product. Identity is entirely Telegram's.

| Actor | Identified by | Can do |
|---|---|---|
| End user (private chat) | `message.from_user.id`, hashed with SHA-256 before it touches storage | Transcribe voice/audio/video notes, `/start`, `/stats`, `/model`, `/payment N`, `/paysupport` |
| Group member in an allow-listed chat | Same hash; chat gated by `ALLOWED_CHAT_IDS` | Have their voice notes and video notes auto-transcribed in the group |
| Any group member replying to the bot | Same hash; gated by the reply containing `BOT_USERNAME` | Trigger transcription of the replied-to voice or audio |
| Operator / admin | `ADMIN_ID` (raw Telegram ID, not hashed) | Receive forwarded + auto-transcribed messages from `FORWARD_CHAT_IDS` chats |
| Django admin site | `django.contrib.auth` password login | Nothing in practice — the route is mounted at `/admin/` (`src/config/urls.py:22`) but `src/bot/admin.py` registers no models and no superuser is created anywhere in the deployment path |

Ownership is implicit and total: a `User` row owns its own `Transcription` and `Payment`
rows via `related_name` cascades (`src/bot/models.py:19-45`). There is no sharing, no
tenancy, no team, and no role column. Every quota check resolves the acting user by hash and
reads only that row.

Notable authorization gap carried in the source: chat allow-listing is done by
`F.chat.id.in_(settings.ALLOWED_CHAT_IDS)` at handler-registration time, and the allow-list
is built by transforming short chat IDs into supergroup IDs with
`-(1000000000000 + int(x))` (`src/config/settings.py:169-183`). Quotas in groups are still
charged to the individual speaker, not to the chat.

## 3. User scenarios — done

### 3.1 Transcribe a voice message in a private chat

`src/bot/handlers/voice.py:15` → `src/bot/services/file_processor.py:317`.

1. User sends a voice message.
2. Bot hashes the sender ID and sets it as the Sentry user context.
3. Quota check (`check_user_limits`): loads or creates the user, resets the free allowance if
   the last reset is older than 30 days, and compares `left_free + left_purchased` against the
   audio duration.
   - Insufficient: reply with `LIMIT_EXCEEDED_MESSAGE` and stop, charging nothing.
   - Below `LEFT_WARNING_SECONDS` and not warned yet: reply with `LIMIT_WARNING_MESSAGE`, stamp
     `warned_at`, and continue.
4. Bot replies "Распознаю..." — this reply message is then edited in place for every
   subsequent progress step (`ProcessStatus`: Скачиваю файл… → Достаю звук из видео… →
   Распознаю… → Отправляю результат…).
5. `bot.get_file` + `bot.download_file` with a 60-second timeout.
6. Transcription with retry: up to `MAX_RETRIES` attempts against the primary engine, with a
   linear backoff of `RETRY_DELAY * attempt` seconds and a progress edit announcing
   "Попытка N/M". If all attempts fail and `FALLBACK_TRANSCRIPTION_ENGINE` is configured, one
   final attempt runs against the fallback engine. The audio buffer is `seek(0)`-rewound before
   every retry (`src/bot/services/file_processor.py:97-134`).
7. Result rendering (`send_results`, `src/bot/services/file_processor.py:271`):
   - Parse the engine answer. Gemini engines return `{"short": ..., "full": ...}` JSON; other
     engines return plain text.
   - `len(full) <= 200`: edit the progress message into a rich message containing a single
     block quotation.
   - Longer: edit into an expandable `details` block whose summary is the model's `short` field,
     falling back to the first line of the transcript truncated to 80 chars, falling back to
     "📝 Транскрипция". The transcript is chunked at `MAX_RICH_MESSAGE_LENGTH - len(summary)`
     (32768 minus summary), the first chunk replaces the progress message, and every further
     chunk is sent as a new rich message replying to the original.
8. Debit: free seconds are spent first, the remainder comes out of purchased seconds
   (`src/bot/services/db.py:44-53`).
9. Log a `Transcription` row with duration and elapsed transcription time.

### 3.2 Failure inside the pipeline

Any exception is caught in `handle_file` (`src/bot/services/file_processor.py:344-370`):

- the progress message is edited into a preformatted block
  `Ошибочка (<STEP_NAME>):\n<error text>`, truncated to 4096 chars;
- Sentry receives the exception plus a `pipeline` context carrying the step name;
- a `Transcription` row is written with `transcription_time = -1` as a failure marker;
- **the user is not charged** — `process_user_transcription` is never reached.

The `finally` block removes `file_info.file_path` if it exists on the local filesystem, which
is the cleanup path for the local `telegram-bot-api` server's downloaded files.

### 3.3 Video note

Same as 3.1, but between download and transcription the file is piped through
`ffmpeg -i <tmp> -vn -c:a copy -f adts -` to strip the video stream, yielding `audio/aac`
(`src/bot/services/file_processor.py:29-46`). A non-zero ffmpeg exit raises with the captured
stderr.

### 3.4 Group transcription

Two distinct paths:

- **Reply-mention** (`src/bot/handlers/voice.py:56-91`): in any group or supergroup, a text
  reply to a voice or audio message whose text contains `BOT_USERNAME` triggers transcription
  of the replied-to media.
- **Allow-listed chat** (`src/bot/handlers/voice.py:93-123`): in a chat whose ID is in
  `ALLOWED_CHAT_IDS`, every voice message and video note is transcribed automatically, with no
  mention needed.

### 3.5 Forward to admin

`src/bot/handlers/forward.py`. In a chat listed in `FORWARD_CHAT_IDS`, every voice, audio and
video note is forwarded to `ADMIN_ID`, followed by a metadata reply
(`From: <chat title> (@<username|id>)` / `User: <full name|id>`), and then transcribed — with
the transcript attached to the *forwarded* copy in the admin's chat, while the quota is
charged to the *original sender's* hash. The whole routine is wrapped in a bare
`except Exception` that only reports to Sentry, so a forwarding failure is silent to everyone
in the source chat.

### 3.6 Buy minutes

`src/bot/handlers/payment.py`.

1. `/payment N` where `1 <= N <= 2500`; anything else replies with a usage hint rendered with
   an inline code span.
2. The bot sends a Telegram Stars invoice (`currency="XTR"`, `provider_token=""`,
   `payload="{N}_stars"`) with a single pay button labelled "Оплатить N XTR".
3. `pre_checkout_query` is answered `ok=True` unconditionally — there is no validation stage.
4. On `successful_payment`: a `Payment` row is written with
   `telegram_payment_charge_id` and `total_amount`, and the user's
   `left_purchased_seconds` grows by `total_amount * CURRENCY_RATE_SECONDS`
   (default 10 minutes = 600 s per star). The user is told how many minutes were credited.

`/paysupport` replies with `SUPPORT_USERNAME`, which Telegram requires for Stars payments.

### 3.7 Informational commands

- `/start` — welcome text with the monthly allowance in minutes.
- `/stats` — free minutes left, purchased minutes left, and the next free-reset date computed
  as `last_free_reset_at + 30 days`, formatted `%d.%m.%Y`.
- `/model` — dumps the raw engine settings; an operator diagnostic exposed to every user
  (`src/bot/handlers/util.py:32-34`).
- Any other text in a private chat — `UNKNOWN_COMMAND_MESSAGE`, which exists to explain to
  people who reply to a forwarded transcription that their reply will not reach the original
  sender.

## 4. Domain model — done

Three concrete tables plus an abstract timestamp mixin. Backing store is SQLite at
`data/db.sqlite3` with a 20-second busy timeout (`src/config/settings.py:79-89`).

### `TimestampModel` (abstract, `src/bot/models.py:5-11`)

`created_at` (`auto_now_add`), `updated_at` (`auto_now`). Mixed into all three models.

### `User` (`src/bot/models.py:14-22`, migration `0001_initial.py:16-45`)

- Purpose: one metered account per Telegram user, holding the quota balance.
- Fields:
  - `id` — `BigAutoField`;
  - `hashed_user_id` — `CharField(max_length=255)`, **unique**; SHA-256 hex digest (64 chars)
    of `str(telegram_user_id)`, computed at every handler entry point;
  - `left_free_seconds` — integer, model default `0`, but every creation path passes
    `defaults=dict(left_free_seconds=AVAILABLE_SECONDS)` (`src/bot/services/db.py:7-12`), so the
    real default is the configured monthly allowance. The `0` default only applies to rows
    created outside `get_or_create_user` — which the tests do
    (`src/bot/tests/user_and_payment_tests.py:43`);
  - `left_purchased_seconds` — integer, default `0`;
  - `last_free_reset_at` — datetime, default `timezone.now`;
  - `warned_at` — nullable datetime; the low-balance warning latch.
- Relationships: `transcriptions` and `payments`, both `CASCADE`.
- Lifecycle: created lazily on first interaction; never deleted; never archived.
- Invariants (enforced only in application code, not by the schema):
  - `hashed_user_id` is unique — the only database-level constraint in the product;
  - balances are expected non-negative, but nothing enforces it. See section 5 for the
    concrete way this breaks.

### `Transcription` (`src/bot/models.py:25-32`)

- Purpose: an anonymous usage log. Deliberately contains no audio and no text.
- Fields: `user` FK (CASCADE, `related_name="transcriptions"`), `audio_duration` (integer
  seconds), `transcription_time` (float seconds, **`-1` means the pipeline failed**).
- Lifecycle: append-only. Written on both success and failure
  (`src/bot/services/file_processor.py:341` and `:367`). Never read back by the product — there
  is no reporting surface at all.

### `Payment` (`src/bot/models.py:35-43`)

- Purpose: a record of a Telegram Stars purchase.
- Fields: `user` FK (CASCADE), `payment_id` — `CharField(max_length=255)` holding
  `telegram_payment_charge_id`, **not unique**; `total_amount` — integer, the number of Stars.
- Lifecycle: append-only, written inside `make_payment` immediately before the balance is
  credited (`src/bot/services/db.py:63-72`). Never refunded, never reversed.
- Invariant that should hold but does not: one credit per charge ID. Section 5 covers this.

## 5. Business rules — done

| # | Rule | Source | Test |
|---|---|---|---|
| R1 | The Telegram user ID is never stored — only `sha256(str(id)).hexdigest()` | `voice.py:16`, `payment.py:36`, `util.py:24`, `forward.py:29` | — |
| R2 | A new account starts with `AVAILABLE_SECONDS` free seconds | `db.py:7-12` | `user_and_payment_tests.py:10-23` |
| R3 | The free allowance resets when `last_free_reset_at < now - 30 days`; the reset also clears `warned_at` | `db.py:15-27` | `edge_cases_tests.py:13-33` (reset), `:36-52` (no reset within 30 days) |
| R4 | The reset is lazy — it fires on the next transcription attempt, never on a schedule | `db.py:20-25` | — |
| R5 | Transcription is refused when `left_free + left_purchased < audio_duration`. The check is against the *whole* combined balance | `db.py:29-30` | `transcription_tests.py:52-63` |
| R6 | Below `LEFT_WARNING_SECONDS` combined balance, warn once, latch on `warned_at`, and continue | `db.py:31-40` | `transcription_tests.py` |
| R7 | Debit order: free seconds first, the shortfall from purchased seconds | `db.py:44-53` | `edge_cases_tests.py:55-73`, `transcription_tests.py` |
| R8 | A failed pipeline charges nothing, but still writes a `Transcription` row with `transcription_time = -1` | `file_processor.py:344-370` | — |
| R9 | One Star buys `CURRENCY_RATE` minutes (default 10 → 600 s) | `db.py:63-72`, `settings.py:165` | `user_and_payment_tests.py:57-81` |
| R10 | A Stars purchase is 1–2500 stars; anything else is rejected with a usage hint | `payment.py:20-33` | — |
| R11 | Transcripts of ≤200 chars render as a block quotation; longer ones as an expandable details block | `file_processor.py:280-291` | `send_results_tests.py` |
| R12 | The details summary is the model's `short`, else the first line of the transcript capped at 80 chars, else "📝 Транскрипция" | `file_processor.py:293-295` | `send_results_tests.py` |
| R13 | Long transcripts are chunked at `32768 - len(summary)`; chunk 1 edits the progress message, the rest are new replies | `file_processor.py:296-310` | `send_results_tests.py` |
| R14 | Malformed engine JSON is salvaged: the `full` field is regex-extracted and Sentry is notified, so the user never sees raw JSON | `file_processor.py:159-210` | `send_results_tests.py` |
| R15 | Primary engine gets `MAX_RETRIES` attempts with linear backoff, then one attempt against the fallback engine | `file_processor.py:97-134` | — |
| R16 | Video notes are converted to AAC with ffmpeg before transcription | `file_processor.py:29-46` | — |
| R17 | Group auto-transcription is limited to `ALLOWED_CHAT_IDS`; forwarding to admin is limited to `FORWARD_CHAT_IDS` | `voice.py:93-123`, `forward.py:47-90` | — |
| R18 | In a group, the reply-mention path works in *any* chat, not just allow-listed ones | `voice.py:56-91` | — |

Defects the target must decide about rather than reproduce blindly:

- **D1 — balances go negative.** R5 checks the *combined* balance but R7 debits free-first
  and then subtracts the shortfall from `left_purchased_seconds` with no floor. Since R5
  guarantees the combined balance covers the duration, the arithmetic is sound in the
  happy path — but the R3 reset and the R7 debit are separate non-atomic `asave()` calls with
  no row lock, so two concurrent voice messages both pass R5 against the same stale balance
  and both debit. SQLite's 20-second busy timeout serialises the writes but not the
  read-modify-write, so the second write clobbers the first.
- **D2 — `Payment.payment_id` is not unique.** Telegram can redeliver a `successful_payment`
  update after a restart with `drop_pending_updates=True` (`bot_init.py:31`) — that flag drops
  pending updates on startup, which is a *different* hazard: a payment that arrived while the
  bot was down is discarded and the user is never credited. Neither direction is guarded.
- **D3 — `process_user_transcription` takes a `transcription_time` argument it never uses**
  (`db.py:42`).
- **D4 — `/model` exposes engine configuration to every user** (`util.py:32-34`).
- **D5 — the free-reset warning latch is cleared on reset but never on a purchase**, so a
  user who was warned, then bought minutes, will not be warned again when the purchased
  balance runs low within the same 30-day window.

## 6. Authentication and authorization — done

- **Bot identity**: the Telegram Bot API token (`TELEGRAM_TOKEN`). Long polling only —
  `delete_webhook(drop_pending_updates=True)` then `dp.start_polling(bot)`
  (`src/bot/bot_init.py:29-32`). No webhook, so no inbound HTTP surface exists.
- **User identity**: derived per-update from `message.from_user.id`, hashed. There is no
  session, no token, and no login.
- **Authorization**: implemented as aiogram router filters, evaluated in router registration
  order — `voice`, `forward`, `payment`, `util` (`src/bot/bot_init.py:22-27`). A message
  matching an earlier router's filter never reaches a later one. This ordering is load-bearing:
  the catch-all `F.text` handler in `util` is last precisely so it does not swallow commands.
- **Admin authorization**: a single integer comparison against `ADMIN_ID`, and only as a
  destination — the admin is never authenticated, only messaged.
- **Web authorization**: `django.contrib.auth` with the admin site mounted at `/admin/`
  (`src/config/urls.py:22`). In practice inert: `src/bot/admin.py` registers nothing, no
  superuser is created by `entrypoint.sh`, and the container runs `runbot`, not a web server —
  so no HTTP port is ever bound in production.
- **Tenancy**: none.

Consequence for the target: the source has no working web authentication to port. The target
nevertheless needs it, because the LiveVue operator UI will expose per-account balances and
payment history that the source never exposed over HTTP. See section 11.

## 7. Background and scheduled work — done

There is **no scheduler, no job queue, and no worker process** in the source. Everything runs
inline in the aiogram event loop.

| Work | Trigger | Durability | Retry | Failure behavior |
|---|---|---|---|---|
| Monthly free-allowance reset | Lazy, on the next transcription attempt (`db.py:20-25`) | None — a user who stops using the bot never resets until they return | n/a | n/a |
| Transcription | Inline, per update | **None.** A restart mid-transcription loses the work; the user is left with a stale "Распознаю..." message forever | `MAX_RETRIES` attempts, linear backoff, then one fallback-engine attempt (`file_processor.py:97-134`) | Progress message becomes an error block, Sentry event, `-1` log row, no charge |
| ffmpeg conversion | Inline subprocess via `asyncio.create_subprocess_exec` | None | None | Raises with captured stderr, handled by the pipeline error path |
| Downloaded-file cleanup | `finally` block in `handle_file` (`file_processor.py:368-370`) | Best-effort. A hard crash leaks the file into the `tmpfs` volume, which is capped at 500 MB (`docker-compose.yml:29-33`) | None | Silent |
| Forward-to-admin | Inline, per update | None | None | Swallowed into Sentry (`forward.py:41-42`) |

Concurrency: aiogram's default dispatcher processes updates concurrently, and no lock or
transaction guards the read-modify-write on `User`. This is the mechanism behind D1.

## 8. External integrations — done

### Telegram Bot API

- Client: `aiogram >= 3.30.0`.
- Transport: long polling.
- **Local Bot API server**: when `TELEGRAM_BOT_API_URL` is set, the session is pointed at a
  self-hosted `aiogram/telegram-bot-api:10.2` container with `TELEGRAM_LOCAL=true`
  (`src/bot/bot_init.py:7-14`, `docker-compose.yml:2-9`). This exists to lift the 20 MB
  download cap of the public API. It changes the download semantics: `get_file` returns a
  local filesystem path rather than a URL, which is exactly why the `finally` block deletes
  `file_info.file_path`. Moving a bot to a local server requires a one-time `logout` call
  against the public API — that is what `logout.sh` is for.
- Bot API features used, with the version that introduced them:
  - Telegram Stars payments (`XTR`, empty `provider_token`) — Bot API 7.4;
  - **Rich messages** — `sendRichMessage`, and `editMessageText` with a `rich_message`
    parameter, using `InputRichMessage(blocks=[...])` with `InputRichBlockDetails`,
    `InputRichBlockBlockQuotation` and `InputRichBlockParagraph`.
    The `blocks` field on `InputRichMessage` was added in **Bot API 10.2** (14 July 2026);
    Bot API 10.1 (11 June 2026) shipped rich messages with only `html` / `markdown`.
    This is the single hardest compatibility constraint in the whole replatforming — see
    section 11.
- Requests are proxied: `docker-compose.yml:13-16` injects `ALL_PROXY` / `HTTP_PROXY` /
  `HTTPS_PROXY` built from `PROXY_USERNAME`/`PASSWORD`/`HOST`/`PORT`. Those four variables are
  read by compose from the shell environment and are **absent from `.env.example`** — an
  undocumented deployment requirement.

### Transcription engines (`src/bot/services/transcribe.py`)

An `ABC` with nine concrete implementations selected by the `TRANSCRIPTION_ENGINE` string.
Note that `get_transcription_client` **instantiates all nine engines** to build its lookup
dict, so every engine's constructor runs on import and a missing `OPENAI_API_KEY` crashes the
process at startup even when Gemini is the configured engine (`transcribe.py:222-241`).

| Engine key | Provider | Call | Output |
|---|---|---|---|
| `openai-whisper` | OpenAI | `audio.transcriptions.create(model="whisper-1", response_format="text")` | plain text |
| `openai-gpt-4o-mini-transcribe` | OpenAI | same, `model="gpt-4o-mini-transcribe"` | plain text |
| `elevenlabs-scribe_v1` | ElevenLabs | `speech_to_text.convert(model_id="scribe_v1")`, `.text or "..."` | plain text |
| `elevenlabs-scribe_v2` | ElevenLabs | same, `scribe_v2` | plain text |
| `gemini-2.5-flash` | Google | Files API upload + `generate_content` with `response_mime_type="application/json"` | `{"short","full"}` JSON |
| `gemini-3-flash-preview` | Google | same | same |
| `gemini-2.5-flash-lite` | Google | same | same |
| `gemini-3.1-flash-lite` | Google | same | same |
| `gemini-3.5-flash-lite` | Google | same — **the default** | same |

The Gemini engines share a single large prompt, `GEMINI_PROMPT`
(`src/config/settings.py:194-317`), which is a genuine product asset, not boilerplate. It
specifies: verbatim transcription preserving slang, profanity and filler words;
`[неразборчиво]` markers with an optional cause; Russian-language bracketed descriptions of
acoustic events; pause representation through punctuation with `[долгая пауза]` reserved for
meaningful silence; paragraph-splitting rules; `Говорящий 1:` / `Говорящий 2:` labels for
multi-speaker audio; sparing emoji for unmistakable emotion; `[Тишина]` for silence; and the
exact two-field JSON output contract with `short` capped at 10 words.

Every Gemini call uploads the audio to the Files API first, then references the uploaded file
handle in `generate_content`. Uploaded files are never explicitly deleted.

### Sentry

`sentry-sdk >= 2.39.0`, initialised in the management command with `traces_sample_rate=1.0`
and `profiles_sample_rate=1.0` (`src/bot/management/commands/runbot.py:17-22`). Used for:
`set_user({"id": hashed_user_id})` at every handler entry, `set_context("pipeline", {"step":
...})` before capturing pipeline failures, `capture_exception` in the pipeline and forward
error paths, and `capture_message` for salvaged malformed JSON.

### ffmpeg

Installed in the image (`Dockerfile:5-7`), invoked as a subprocess for video-note audio
extraction. A hard runtime dependency of the container.

## 9. Frontend behavior — done

**The source product has no frontend.** No templates directory, no static assets, no JS
toolchain, no HTTP route other than the inert `/admin/`, and no web server in the deployment
— the container's command is `uv run src/manage.py runbot` (`docker-compose.yml:19`).

The "UI" is the Telegram chat surface, and it has real interaction design worth preserving:

- **Optimistic progress**: a single reply message is created immediately and then edited in
  place through the pipeline stages. Progress edits are wrapped in a bare `try/except pass`
  (`file_processor.py:322-329`) so that a Telegram rate-limit on an edit never kills the
  transcription.
- **Result rendering**: the same message becomes the result — a block quotation for short
  transcripts, an expandable collapsed block for long ones. The collapse threshold is by
  *character length*, not newline count; commit `fb11451` in the source history is the fix
  that established this.
- **Overflow**: transcripts beyond one rich message become additional replies threaded to the
  original voice message via `as_reply_parameters()`.
- **Errors**: rendered as a preformatted block naming the failed stage.

Consequence for the target: since `STACK_POLICY.md` mandates LiveVue for the entire UI, and
the source has no UI to port, the target's LiveVue surface is **new product surface**, not a
migration. It should be scoped as an operator console rather than an invented end-user app:
account lookup by hash, balance and quota inspection, usage and failure-rate charts over the
`Transcription` log (which the source writes but never reads), payment history, and engine
health / fallback rates. Section 12 details this.

## 10. Data migration and compatibility — done

- **Store change**: SQLite file at `data/db.sqlite3` → PostgreSQL. Volume is trivial (three
  narrow tables, one row per user). A one-shot export/import script is sufficient; no
  online migration is needed.
- **Identifiers**: Django `BigAutoField` integer PKs. Ash defaults to UUID v7 primary keys.
  Since `hashed_user_id` is the only externally meaningful key and nothing outside the
  database references the integer IDs, the target should adopt UUID primary keys and keep
  `hashed_user_id` as a unique identity attribute. Nothing breaks.
- **`hashed_user_id` must stay bit-identical**: `sha256(str(telegram_user_id)).hexdigest()`,
  lowercase hex, 64 chars. Getting this wrong silently orphans every existing balance. In
  Elixir: `:crypto.hash(:sha256, Integer.to_string(id)) |> Base.encode16(case: :lower)`.
  This needs a test that pins a known ID to a known digest.
- **Timestamps**: Django stores UTC (`USE_TZ = True`, `TIME_ZONE = "UTC"`). Map to
  `:utc_datetime_usec`. `created_at`/`updated_at` map to Ash `create_timestamp` /
  `update_timestamp`; `last_free_reset_at` and `warned_at` are ordinary attributes, the latter
  nullable.
- **The `-1` sentinel** in `Transcription.transcription_time` is a failure marker, not a
  duration. The target should model this honestly — a `status` attribute (`:succeeded` /
  `:failed`) with a nullable duration — and translate `-1` to `:failed` during import.
- **Missing constraints to add on the way in**: unique index on `Payment.payment_id`
  (idempotent Stars credit, defect D2), and non-negative checks on both balance columns
  (defect D1).
- **Secrets**: `SECRET_KEY`, `TELEGRAM_TOKEN`, `OPENAI_API_KEY`, `ELEVENLABS_API_KEY`,
  `GEMINI_API_KEY`, `SENTRY_DSN`, `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, plus the four
  undocumented `PROXY_*` variables. None are stored in the database. Django's `SECRET_KEY`
  has no equivalent role in the target and is replaced by Phoenix's `SECRET_KEY_BASE`.
- **Files**: no user files are persisted. The `tmpfs` volume shared between the bot and the
  local Bot API container is scratch space only.
- **Historical data risk**: `left_free_seconds` for rows created outside `get_or_create_user`
  defaults to `0` rather than the monthly allowance. Import should not "repair" these — the
  reset rule (R3) will correct them naturally on the next use.

## 11. Target dependencies — done

Foundation from `STACK_POLICY.md`, always installed: `ash`, `ash_phoenix` (Phoenix),
`ash_postgres` (Postgres), `usage_rules`, and `live_vue` as the manual overlay.

### Background and scheduled work — AshOban

- Source behavior: the free-allowance reset is lazy and never fires for dormant users (R4);
  transcription retries are in-process and a restart loses the work entirely (section 7);
  `drop_pending_updates=True` discards payments that arrived while the bot was down (D2).
  All three are durability problems that a job queue solves.
- Selected package or installer feature: `oban` feature → `ash_oban` 0.8.11 + `oban_web`
  2.12.6.
- Installer requirements and arguments: no feature arguments; requires the Postgres data
  layer, which is already selected.
- Configuration and migration work: Oban migrations; a cron trigger for the monthly reset; an
  `AshOban.trigger` on the transcription resource with a backoff matching R15; `oban_web`
  mounted behind operator authentication.

### Operator interface — AshAdmin

- Source behavior: `/admin/` is mounted in `src/config/urls.py:22` with `django.contrib.admin`
  in `INSTALLED_APPS`. Honest caveat: it registers no models and no superuser is ever created,
  so it does nothing today. The justification is therefore weak on its own — it is selected
  because the target needs a zero-effort way to call resource actions while the LiveVue console
  is being built, and it costs one dependency.
- Selected package or installer feature: `admin` feature → `ash_admin` 1.2.0.
- Installer requirements and arguments: none.
- Configuration and migration work: mount behind the same authentication as the operator
  console; disable in production if the LiveVue console supersedes it.

### Operator authentication — AshAuthentication, password strategy

- Source behavior: `django.contrib.auth` password login guarding `/admin/`
  (`src/config/settings.py:38-45`, `src/config/urls.py:22`). This is the only web
  authentication the source has, and it is inert in practice.
- Additional justification: the target's LiveVue console will expose per-account balances,
  payment history and usage logs over HTTP — data the source never served. Leaving that
  unauthenticated is not an acceptable simplification.
- Selected package or installer feature: `password_auth`. The catalog advertises
  `ash_authentication` 5.0.0-rc.12 and `ash_authentication_phoenix` 3.0.0-rc.9, but the
  installer wrote `~> 4.0` / `~> 2.0` constraints and Hex resolved the **stable**
  `ash_authentication` 4.14.1 and `ash_authentication_phoenix` 2.17.2. No release candidate
  is in the lock file — better than the catalog implied.
- Installer requirements and arguments: `--auth-strategy password`, requires `phoenix`.
- Configuration and migration work: the generated `Accounts.User` resource is the **operator**,
  and must not be confused with the bot's metered account. Name them distinctly —
  `Accounts.Operator` and `Metering.Subscriber` — before writing any code. Registration should
  be closed (invite or seed only); this is a single-operator product.

### Telegram Bot API client — ex_gram (not in the curated catalog)

Verified against the catalog's uncurated-package checklist:

1. Concrete requirement: the entire product is a Telegram bot. Non-negotiable.
2. Ash compatibility: not an Ash extension — an independent OTP application. No conflict.
3. Latest release: `ex_gram` 0.67.0, 12 June 2026. The 0.67.0 release merged PR #216
   "update_10.1" and added Elixir 1.20 support the same day. Six releases in 2026.
   The alternative, `telegex`, last published 1.8.0 on 18 September 2024 — nearly two years
   stale, and rejected on that basis.
4. Documentation: hexdocs plus a maintained README; the API surface is generated from the
   official Bot API documentation.
5. Maintainer: `rockneurotiko`, sole maintainer, consistently active.
6. `usage-rules.md` / package skills: none. Rules for it must be hand-written in the target's
   `AGENTS.md`.
7. Igniter installer: none. Plain dependency addition.
8. Simpler built-in alternative: writing a Bot API client from scratch over `Req` — rejected;
   ex_gram brings the polling dispatcher, update casting, file handling, middleware and a
   test harness.

**Known gap, and the reason this is called out here rather than discovered mid-implementation:**
ex_gram 0.67.0 tracks Bot API **10.1**. Its `InputRichMessage` model carries `html`,
`markdown` and `is_rtl` (verified by extracting the published hex tarball and reading
`lib/ex_gram.ex:6856-6875`). It has **no** `blocks` field and no `InputRichBlock*` structs,
because those arrived in Bot API 10.2. The source product depends on the 10.2 block shape
(`src/bot/services/file_processor.py:14-19`).

Mitigation, in preference order:

1. Use ex_gram for polling, dispatch, file download and every ordinary send.
2. Build the two rich-message calls — `sendRichMessage` and `editMessageText` with
   `rich_message` — as hand-rolled JSON payloads over `Req` against the same base URL and
   token. The payload is plain JSON; no library support is needed to construct it.
3. Revisit when ex_gram ships 10.2 support and replace the hand-rolled calls.

This must be isolated behind one module so the eventual swap is local.

**Second known issue, found during installation:** ex_gram declares
`{:req, "~> 0.5.0", optional: true}`, and Hex enforces that bound whenever `req` is in the
tree — which it is, because `phx.new` adds it. Every `req` 0.5.x is affected by
**EEF-CVE-2026-49755 (HIGH)**, a decompression-bomb DoS via auto-decoded compressed response
bodies, fixed only in 0.6.1. Since this product downloads attacker-supplied audio and calls
external HTTP APIs, that is squarely on the attack path and cannot be accepted.

Resolved with `{:req, "~> 0.7", override: true}`, then **verified at runtime, not just
compiled**: `ExGram.get_me/1` through `ExGram.Adapter.Req` against the real Bot API returned a
correctly mapped `%ExGram.Error{code: 401}`, exercising request construction, the base-URL
step, JSON encoding, the HTTP round trip, decoding and error mapping. The multipart path used
for audio uploads was checked separately — `Req.Utils.encode_form_multipart/1` still produces
a valid boundary and size under 0.7.2. Drop the override once ex_gram widens its constraint.

### HTTP client — Req (not in the curated catalog)

- Source behavior: three transcription providers plus the 10.2 rich-message gap above.
  `openai`, `elevenlabs` and `google-genai` have no maintained Elixir equivalents worth
  adopting; all three are straightforward REST APIs, and the Gemini path is a Files API
  multipart upload followed by a `generateContent` POST.
- Selected package: `req` 0.7.2 (31 July 2026), added by `phx.new` and kept with
  `override: true` for the CVE reason described above. The de-facto standard Elixir HTTP
  client, and the same one ex_gram uses, so the bot and the engines share one stack.
- Configuration and migration work: one behaviour module mirroring the source's
  `TranscriptionService` ABC, one implementation per engine, and a registry keyed by the
  `TRANSCRIPTION_ENGINE` string. **Build the registry lazily** — the source's eager
  instantiation of all nine engines at import time (`transcribe.py:222-241`) is a defect worth
  not reproducing.

### Error tracking — Sentry (not in the curated catalog)

- Source behavior: `sentry-sdk` with user context, pipeline context, exception capture and
  message capture (section 8).
- Selected package: `sentry` 13.3.0 (7 July 2026), the official Elixir client, 1.3M recent
  downloads. Ships a `LoggerHandler` and Plug integration.
- Configuration and migration work: `SENTRY_DSN` at runtime, `Sentry.Context.set_user_context/1`
  at each handler entry, `set_extra_context/1` for the pipeline step. The catalog offers
  `appsignal` and `opentelemetry` for this slot; both are marked "coming soon/manual setup" and
  neither matches the incumbent. Sentry keeps the existing dashboards and alert routing.

### Explicitly rejected

| Capability | Why not |
|---|---|
| `graphql`, `json_api` | No external or mobile API contract exists. The only client is Telegram. |
| `ash_typescript` | Its installer targets React; this stack is Vue. `SELECTION_HEURISTICS.md` requires verifying Vue support first, and there is no typed-API surface to generate against anyway. |
| `sqlite`, `csv` | Postgres is the policy default and is required by AshOban. The source's SQLite choice was convenience, not a constraint. |
| `magic_link_auth`, `api_key_auth`, `oauth` | The source supports none of them. One operator, one password. |
| `state_machine` | The `ProcessStatus` enum drives progress text; it is never persisted and has no enforced transitions. Per the heuristics, a status label is not a state machine. |
| `ash_events` | No replay or persisted-action-log requirement. `Transcription` is already the usage log. |
| `money`, `double_entry` | Telegram Stars are integer counts, and the ledger is a single integer balance. No currency arithmetic, no accounts to balance. |
| `archival` | Nothing is ever deleted today; there is no soft-delete requirement to enforce. |
| `paper_trail` | No audit requirement. Recording who changed a balance would work against the product's explicit privacy promise. |
| `cloak` | The one sensitive identifier is already a one-way SHA-256 hash. Encryption at rest adds key management for no gain. |
| `ash_ai` | Tempting, since transcription is LLM-driven — but the calls are audio uploads to a Files API followed by structured `generateContent`, not chat completions, and two of the five providers (ElevenLabs, Whisper) are not LLM chat at all. A `Req` behaviour is simpler and covers all five. Revisit if the product grows genuine agentic behavior. |
| `tidewave`, `live_debugger` | Development tooling, not product capability. Add locally at will. |
| `cinder` | Ash-aware LiveView data tables, which overlap with the LiveVue console this stack mandates. |
| `mishka` | Generates Phoenix/LiveView component templates; the same overlap. |

## 12. Target architecture — done

### Applications

Two supervised trees in one OTP application:

1. **The bot** — an ex_gram polling dispatcher plus handler modules. This is the product.
2. **The web endpoint** — Phoenix + LiveView + LiveVue, serving the operator console. New
   surface; see section 9.

### Ash Domains

**`Metering`** — the quota ledger. The core of the product.

- `Metering.Subscriber` (was Django `User`)
  - `hashed_user_id` (unique identity), `left_free_seconds`, `left_purchased_seconds`,
    `last_free_reset_at`, `warned_at`.
  - Actions: `:find_or_register` (upsert on `hashed_user_id`, seeding the free allowance, R2);
    `:reserve` (the R3 reset + R5/R6 check, returning `:ok | :warn | :exceeded`);
    `:debit` (R7, free-first); `:credit_purchase` (R9).
  - `:reserve` and `:debit` must run in one transaction with a row lock. This is the fix for
    defect D1 and the single most important behavioral improvement in the replatforming.
  - Check constraints: both balances `>= 0`.
  - Calculations: `total_seconds`, `free_minutes`, `purchased_minutes` (the source's `ceil`
    minute rounding, `messages.py`, belongs here rather than in message formatting).
- `Metering.TranscriptionLog` (was `Transcription`)
  - `audio_duration`, `duration_ms`, `status` (`:succeeded | :failed`), `subscriber` belongs_to.
  - Replaces the `-1` sentinel (section 10). Append-only via a single `:record` action.
- `Metering.Payment`
  - `charge_id` (**unique** — fixes D2), `stars`, `subscriber` belongs_to.
  - `:credit` action, idempotent on `charge_id`, crediting the balance in the same transaction.
- AshOban triggers: a monthly cron reset for all subscribers whose
  `last_free_reset_at < now - 30 days` (fixes R4/D-dormant-users).

**`Transcribing`** — the pipeline.

- Not every step needs to be a resource. The engine behaviour, the ffmpeg conversion and the
  rich-message rendering are plain Elixir modules; `STACK_POLICY.md` is explicit that
  deterministic rules stay in deterministic code.
- `Transcribing.Job` as an Ash resource **only** if transcription becomes a durable AshOban
  job — which section 7 argues it should, so that a restart does not strand a user on
  "Распознаю...". Attributes: telegram chat/message IDs, file ID, duration, engine, attempt
  count, status.
- `Transcribing.Engine` behaviour with `transcribe(audio, mime_type)`, implementations for
  Whisper, gpt-4o-mini-transcribe, Scribe v1/v2, and the five Gemini variants. Lazy registry.
- `Transcribing.ResponseParser` — a direct port of `parse_transcription_response` and its JSON
  salvage (R14). The source's tests in `src/bot/tests/send_results_tests.py` are the
  specification; port them first.
- `Transcribing.RichMessage` — the isolated Bot API 10.2 module from section 11: block
  quotation vs expandable details, summary selection (R12), chunking (R13).

**`Accounts`** — operator identity only. The generated `ash_authentication` resource, renamed
`Operator` to keep it distinct from `Metering.Subscriber`.

### Bot layer

- `Bot.Dispatcher` — ex_gram handler. Router precedence must reproduce the source's
  registration order (section 6): voice → forward → payment → util, with the catch-all text
  handler last.
- `Bot.Handlers.Voice`, `.Forward`, `.Payment`, `.Util` — thin, mapping updates onto Ash
  actions.
- `Bot.Identity` — the SHA-256 hash, with the pinned digest test from section 10.
- `Bot.Progress` — the in-place message-edit state machine, with edit failures swallowed
  exactly as the source does.

### LiveVue console

LiveView owns routing, session, subscriptions and authoritative state; every screen renders
through Vue components.

- `/` — dashboard: transcriptions per day, success/failure rate from `TranscriptionLog`,
  engine mix, fallback rate. Vue chart components fed by LiveView assigns.
- `/subscribers` — lookup by hashed ID, balances, usage history. Vue table with server-side
  filtering through LiveView events.
- `/payments` — Stars purchase history.
- `/engines` — current primary and fallback engine, recent error rates. Replaces the `/model`
  command's operator purpose so it can be removed from the bot (fixes D4).
- Live updates over Phoenix PubSub as transcriptions complete.
- `/admin` — AshAdmin, and `/oban` — Oban Web, both behind the operator session.

### Configuration

Every source setting becomes runtime config in `config/runtime.exs`, read from the environment.
`ALLOWED_CHAT_IDS` / `FORWARD_CHAT_IDS` keep the source's
`-(1_000_000_000_000 + id)` supergroup transformation (`src/config/settings.py:169-183`) —
surprising, but it is the existing operational contract and changing it would break every
deployed allow-list.

## 13. First vertical slice — done, implemented

**Transcribe a voice message in a private chat, end to end, metered.**

> **Status: implemented.** See section 16 for what shipped, what it deviates
> from, and what was verified.

This is scenario 3.1 with the group, forwarding and payment paths deliberately excluded. It is
the smallest slice that exercises the bot transport, the metering ledger, an external engine,
the Bot API 10.2 rich-message gap, and the failure path — that is, every risk identified above.

- **User-visible start**: a user sends a voice message to the bot in a private chat.
- **User-visible finish**: the bot's reply message has been edited in place into the transcript
  — a block quotation when short, an expandable details block when long — and `/stats` reports
  a balance reduced by the audio duration.
- **Resources and actions**: `Metering.Subscriber` with `:find_or_register`, `:reserve` and
  `:debit`; `Metering.TranscriptionLog` with `:record`.
- **Authorization**: none at the bot layer beyond the source's own filters — identity is the
  hashed Telegram ID. The operator console is not part of this slice.
- **UI path**: none. This slice is bot-only, and that is deliberate — the LiveVue console has
  no source behavior to port and must not block the product's actual function.
- **Tests**:
  - the pinned SHA-256 digest test from section 10;
  - a port of `src/bot/tests/send_results_tests.py` against `Transcribing.ResponseParser` —
    valid JSON, malformed JSON salvage, plain text, the 200-char threshold, summary fallback
    order, and chunk boundaries;
  - a port of `transcription_tests.py` and `edge_cases_tests.py` against `:reserve` / `:debit`
    — free, purchased, mixed, exceeded, warning latch, 30-day reset, exact-boundary usage;
  - a **new** concurrency test that D1 would fail: two simultaneous `:reserve` + `:debit`
    cycles against one subscriber must not overdraw the balance;
  - one engine test against a stubbed `Transcribing.Engine`.
- **Verification**: `mix test`, plus a manual round trip against a real bot token with
  `GEMINI_API_KEY` set, confirming both the short and long rendering paths.
- **Scope boundary — explicitly not in this slice**: group handlers, reply-mention handling,
  forward-to-admin, Telegram Stars payments, the LiveVue console, AshAdmin, Oban Web, the
  monthly-reset cron, the local Bot API server, ffmpeg video-note conversion, and the SQLite
  data import.

## 14. Bootstrap command — done

Archives first:

```bash
mix archive.install hex igniter_new --force
mix archive.install hex phx_new 1.8.9 --force
```

Project creation (Postgres is the `phx.new` default, so no `--with-args` is needed):

```bash
mix igniter.new telegram_voice_transcriber_ash \
  --with phx.new \
  --install ash,ash_phoenix \
  --install ash_postgres,ash_authentication \
  --install ash_authentication_phoenix,ash_admin \
  --install ash_oban,oban_web \
  --install usage_rules \
  --auth-strategy password \
  --setup \
  --yes
```

Then, from the target root:

```bash
mix igniter.install live_vue --yes
mix igniter.install ex_gram sentry --yes
```

`req` needed no installer — `phx.new` already adds it. `ex_gram` ships no Igniter installer,
so it was added as a plain dependency; `sentry.install` ran.

Both extra installs needed intervention, recorded here so a repeat run is not a surprise:

1. `mix igniter.install live_vue` crashed in `phoenix_vite` 0.5.0 with
   `%Rewrite.Error{reason: :nosource, path: "assets/css/app.css"}`. Its `has_tailwind?/1`
   checks `Igniter.exists?/2`, which reads the filesystem, then calls `Rewrite.source/2`,
   which only reads Igniter's in-memory source set — where the file was never included.
   The regression is new in 0.5.0; 0.4.3 has no such function. Worked around by adding the
   missing `Igniter.include_existing_file/2` call to the dependency, running the installer,
   and then restoring the dependency to pristine with `mix deps.clean phoenix_vite`.
   Without the workaround the generated `vite.config.mjs` silently omits the Tailwind plugin
   and drops `css/app.css` from the rollup input.
2. `ex_gram` forced the `req` downgrade described in section 11, resolved with an override.

Capability → package → argument map:

| Capability | Feature | Packages | Installer argument |
|---|---|---|---|
| Web layer | `phoenix` | `ash_phoenix` | `--with phx.new` |
| Data layer | `postgres` | `ash_postgres` | (default) |
| Operator login | `password_auth` | `ash_authentication`, `ash_authentication_phoenix` | `--auth-strategy password` |
| Operator UI | `admin` | `ash_admin` | — |
| Durable work | `oban` | `ash_oban`, `oban_web` | — |
| Agent rules | `usage_rules` | `usage_rules` | — |
| Vue UI layer | manual overlay | `live_vue` | separate installer |
| Telegram client | uncurated | `ex_gram` | separate installer |
| Error tracking | uncurated | `sentry` | separate installer |
| HTTP client | uncurated | `req` | separate installer |

Target application name: the source directory is `telegram_voice_transciber`, which carries a
typo. `pyproject.toml` spells it `transcriber`. The target uses the corrected
`telegram_voice_transcriber_ash` — recorded here because it is a deliberate deviation from a
literal derivation of the directory name.

## 15. Open questions

1. **Rich messages.** The ex_gram / Bot API 10.2 gap (section 11) is the top technical risk.
   The hand-rolled `Req` path is straightforward, but it needs verification against a live bot
   early — a rendering regression here is the most user-visible failure mode the product has.
2. **Is the LiveVue console wanted at all?** `STACK_POLICY.md` mandates LiveVue for the whole
   UI, but the source has no UI. The operator console in section 12 is a proposal, not a
   migration. It may be over-scoped for a single-operator bot, and the honest alternative is
   AshAdmin plus Oban Web and nothing else. This is a product decision.
3. **Should transcription become a durable Oban job?** It fixes the stranded-"Распознаю..."
   failure and enables real backoff, but it changes the latency profile and moves the progress
   edits into a worker. Recommended, but it is a behavior change, not a port.
4. **Payment idempotency and `drop_pending_updates`.** Fixing D2 properly means dropping
   `drop_pending_updates: true` and making the payment credit idempotent on `charge_id`.
   Confirm no operational reason required that flag.
5. **The four undocumented `PROXY_*` variables** (section 8). They are required by the source's
   compose file but absent from `.env.example`. Confirm whether the proxy is still needed and
   document it in the target.
6. **Should `/model` survive?** It leaks engine configuration to every user (D4). The console's
   `/engines` screen covers the operator need.
7. **Data import timing.** A one-shot SQLite → Postgres script is trivial, but it must run
   against a stopped bot to avoid split-brain balances. Confirm an acceptable maintenance
   window.
8. **The `req` override is load-bearing.** `{:req, "~> 0.7", override: true}` in `mix.exs`
   exists to keep a HIGH-severity CVE out of the tree while still using ex_gram. Do not
   "clean it up". Remove it only when ex_gram widens its own constraint, and re-run the
   adapter smoke test when you do.
9. **Bot API 10.2 vs ex_gram 10.1** (see also question 1). If the hand-rolled rich-message
   path proves painful, the fallback is to reconsider ex_gram entirely and write a small
   Bot API client over Req — the polling loop and update dispatch are the only parts that
   would need replacing.

## 16. Slice log

### Slice 1 — transcribe a voice message in a private chat, metered (done)

Section 13, implemented as described, with the deviations below. Also covers
audio files in private chats, since it is the same handler shape; video notes
are not covered, because they need the ffmpeg step that section 13 excludes.

**What shipped**

| Layer | Modules |
|---|---|
| Domain | `Metering` — `Subscriber` (`:find_or_register`, `:reserve`, `:apply_free_reset`, `:mark_warned`, `:debit`), `TranscriptionLog` (`:record`) |
| Migration | `priv/repo/migrations/*_add_metering_ledger.exs` — generated with `mix ash.codegen` |
| Pipeline | `Transcribing.ResponseParser`, `Transcribing.RichMessage`, `Transcribing.Engine` + `Engines.{Gemini,OpenAI,ElevenLabs}` |
| Bot | `Bot` (ex_gram, `/start`, `/stats`, private voice and audio), `Bot.Pipeline`, `Bot.Identity`, `Bot.Messages` |
| Config | `Settings`, the bot block in `config/runtime.exs`, `.env.example` |
| Console | AshAdmin at `/admin` and Oban Web at `/oban`, both behind HTTP basic auth |

**Deviations from the plan, and why**

1. **Rich messages go through ex_gram, not hand-rolled `Req` calls.** Section 11
   proposed building `sendRichMessage` and `editMessageText` by hand because
   ex_gram 0.67 models Bot API 10.1. In practice ex_gram already exposes both
   methods and only its `InputRichMessage` *struct* is behind; adding the
   `blocks` field to that struct is enough, because ex_gram serialises the
   struct as a plain map. Verified on the wire against a local echo server:
   the JSON is byte-for-byte the shape the source's aiogram payload produces.
   The hack is isolated in `RichMessage.input_rich_message/1`.
2. **Gemini sends audio inline instead of uploading to the Files API.** One
   request instead of two, and nothing is left behind on Google's side — the
   source never deleted its uploads. Ceiling: roughly 20 MB per request, which
   is also the public Bot API's download cap.
3. **`:reserve` and `:debit` are not one locked transaction.** Holding a row
   lock across a multi-second engine call is worse than the problem it solves.
   Instead `:debit` is a single atomic `UPDATE` that clamps both balances at
   zero, which is what actually fixes D1: balances can no longer go negative.
   The residue is that a concurrent burst can overspend by at most one
   message's duration. A reservation row would close that; nothing suggests it
   is worth one yet.
4. **`:reserve` returns `:ok | :warn | :exceeded`.** The source's `"success"`
   and `"warned"` both continue and differ only in whether the warning is
   shown, so they collapse into `:ok`.
5. **The free-allowance default lives in the resource**, not in every creation
   path, so the section 4 discrepancy (model default `0` vs the real default)
   does not survive the port.

**Defect found while implementing**

- **D6 — the quota messages mislabel the balance.** `limit_exceeded_message`
  and `limit_warning_message` print the *remaining* balance under the label
  "Использовано" (`src/bot/messages.py:51-78`), so a user with nothing left
  reads "Использовано: 0/30 минут". Ported verbatim: it is user-visible copy,
  and changing it is a product decision, not a port.

**Verification**

| Step | Result |
|---|---|
| `mix format` | passed |
| `mix compile --warnings-as-errors` | passed |
| `mix test` | passed, 51/51 |
| `mix ash.migrate` | passed |
| Dev server, `/` | passed, 200 |
| `/admin`, `/oban` without credentials | passed, 401 |
| `/admin`, `/oban` with credentials | passed, 200; AshAdmin lists the Metering domain |
| Rich-message JSON on the wire, through the real Req adapter | passed — `{"rich_message":{"blocks":[{"type":"blockquote",...}]}}` |
| Live round trip against a real bot token and `GEMINI_API_KEY` | **not verified** — no credentials are available in this environment |
| Release and Docker rebuild | **not run** — no dependency, asset or Dockerfile change in this slice |

**Product decisions taken during this slice**

- The LiveVue operator console (open question 2) is **deferred**. The console
  is AshAdmin plus Oban Web, closed behind HTTP basic auth
  (`OPERATOR_USERNAME` / `OPERATOR_PASSWORD`, 404 when unset). Section 12's
  `/subscribers`, `/payments` and `/engines` screens are not being built for
  now.

**Next slice.** Telegram Stars payments (scenario 3.6): `Metering.Payment`
with a unique `charge_id` and an idempotent `:credit`, `/payment N`,
`/paysupport`, and the `pre_checkout_query` answer. It is the only remaining
path that touches the ledger, and it closes defect D2. Group transcription
(3.4), forwarding (3.5) and video notes are each smaller and independent.

### Slice 2 — buy minutes with Telegram Stars (done)

Scenario 3.6, complete: `/payment N`, the Stars invoice, the pre-checkout
answer, the credit on `successful_payment`, and `/paysupport`.

**What shipped**

| Layer | Modules |
|---|---|
| Domain | `Metering.Payment` — `:credit` (idempotent, transactional), `:record`, `:by_charge_id`; `Subscriber.:credit_seconds` |
| Migration | `priv/repo/migrations/*_add_stars_payments.exs` — unique index on `charge_id` |
| Bot | `Bot.Payments`, four new clauses in `Bot`, three new messages in `Bot.Messages` |
| Config | `CURRENCY_RATE` and `SUPPORT_USERNAME` are now read |

**Defects fixed**

- **D2 — a charge could be credited twice.** `charge_id` is unique, and
  `:credit` returns the existing purchase instead of crediting again, so a
  redelivered `successful_payment` is harmless. The user is still confirmed, as
  the source did.
- **D2, the other direction — payments lost while the bot was down.** The
  source passed `drop_pending_updates=True`; ex_gram's poller calls
  `delete_webhook` without it, so Telegram redelivers what it buffered. That is
  only safe because the credit is idempotent — the two halves of D2 had to be
  fixed together. Nothing to configure; the default is now correct.
- **D5 — the warning latch survived a purchase.** `:credit_seconds` clears
  `warned_at`, so a user who tops up gets warned again when the new balance
  runs low.

**Deviation from the plan**

`Payment` carries a `seconds_credited` column that the analysis's model did
not list. `CURRENCY_RATE` is runtime configuration; without recording what was
actually granted, a rate change makes purchase history unreadable, and it
cannot be reconstructed afterwards.

**Kept as-is**

The pre-checkout query is still answered `ok: true` unconditionally. There is
nothing to validate: the amount is fixed by the invoice the bot itself sent,
and Telegram allows ten seconds to answer.

**Verification**

| Step | Result |
|---|---|
| `mix format`, `mix compile --warnings-as-errors` | passed |
| `mix test` | passed, 69/69 |
| `mix ash.migrate` | passed |
| Dev server, `/` and `/admin` | passed, 200 |
| Routing through the real ex_gram dispatcher — `/start`, `/stats`, `/payment 42`, pre-checkout, `successful_payment`, and a voice message end to end | passed |
| Live round trip against real Telegram Stars | **not verified** — no credentials, and Stars purchases cannot be exercised without a real bot and a real payer |

**Next slice.** Group transcription (scenario 3.4): the reply-mention path in
any group and the automatic path in `ALLOWED_CHAT_IDS` chats, including the
`-(1_000_000_000_000 + id)` chat-ID transformation. After that, forwarding to
the operator (3.5) and video notes with the ffmpeg step.

### Slice 3 — video notes, group transcription, forwarding to the operator (done)

Scenarios 3.3, 3.4 and 3.5, which is every remaining bot path. The three ship
together because they interlock: allow-listed groups auto-transcribe video
notes, and forwarding covers all three media kinds, so neither group path is
complete without the ffmpeg step.

**What shipped**

| Layer | Modules |
|---|---|
| Pipeline | `Transcribing.Audio` — the ffmpeg step (R16), wired in as a `:convert` stage for video notes only |
| Bot | `Bot.Media` (the three media kinds, shared by every entry point), `Bot.Forward`, three new clauses in `Bot` |
| Pipeline | `Pipeline.run/3` takes `:hashed_user_id`, so the forwarding path can deliver to the operator while charging the sender |
| Config | `BOT_USERNAME`, `ALLOWED_CHAT_IDS`, `FORWARD_CHAT_IDS` and `ADMIN_ID` are now read |

**Behaviour preserved exactly, including the odd parts**

- The `-(1_000_000_000_000 + id)` short-chat-ID transformation, because every
  deployed allow-list is written in the short form.
- R18: a reply mentioning the bot transcribes in *any* group, allow-listed or
  not. It reads like a bug next to R17, but it is a feature people use.
- Allow-listed chats transcribe voice notes and video notes but not audio
  files; the reply-mention path takes voice and audio but not video notes.
  Both asymmetries are the source's.
- A chat in both lists is transcribed in place, never forwarded — the source's
  router order decided that, and clause order reproduces it.
- A forwarding failure is swallowed into Sentry and the log, and never surfaces
  in the chat the message came from.

**Deviation**

`convert_video_to_audio` piped ffmpeg's stdout; this writes a second temp file
instead, so ffmpeg's own error text can be captured and reported rather than
being lost to the console. Both files are removed in an `after` block.

**Verification**

| Step | Result |
|---|---|
| `mix format`, `mix compile --warnings-as-errors` | passed |
| `mix test` | passed, 82/82 |
| ffmpeg conversion against a real generated video note, and against garbage | passed — ADTS output, ffmpeg's complaint returned as an error, no temp files left behind |
| Group routing through the real ex_gram dispatcher: allow-listed voice, allow-listed audio (ignored), unlisted group (ignored), reply mention in an unlisted group, reply without the mention, mention replying to plain text, forward with annotation, forward with no operator configured, forward that fails | passed |
| Live round trip against real Telegram | **not verified** — no credentials |

### Slice 4 — the nightly free-allowance sweep and the SQLite import (done)

The two remaining non-UI items from the analysis: R4's "the reset never fires
on a schedule", and section 10's data migration.

**The sweep.** An AshOban trigger on `Subscriber`, `17 3 * * *`, selecting
`last_free_reset_at < ago(30, :day)` and running the existing
`:apply_free_reset` action per record. `:reserve` still resets on the spot when
a stale account is used, so the two paths cannot disagree — the sweep only
means a dormant account no longer shows a stale balance in `/stats` or in the
operator console. Registered crontab entry verified:
`{"17 3 * * *", …Schedulers.ResetFreeAllowance, []}` with the `default` queue.

**The import.** `mix import_django PATH_TO_DB_SQLITE3`, run against a stopped
bot. Reading goes through the `sqlite3` CLI rather than an Elixir driver: it
runs once, and a driver would be a permanent dependency for a one-shot job.
It translates what section 10 said it would — integer keys to UUIDs, the `-1`
sentinel to `status: :failed`, `payment_id` to a unique `charge_id` — and is
idempotent on `hashed_user_id` and `charge_id`, so a half-finished run can be
repeated.

Two things it does *not* repair, deliberately:

- accounts whose `left_free_seconds` is `0` because they were created outside
  `get_or_create_user` are imported as-is; the reset rule fixes them on its own;
- `seconds_credited` on historical payments is reconstructed from the *current*
  `CURRENCY_RATE`, because the source never recorded the rate in force at the
  time. Duplicate `payment_id` rows — which the source's schema allowed — are
  reported and skipped rather than merged.

A new `:import` action on `Subscriber` exists solely for this task and writes
the balances verbatim.

**Verification**

| Step | Result |
|---|---|
| `mix format`, `mix compile --warnings-as-errors` | passed |
| `mix test` | passed, 89/89 |
| Sweep against seeded accounts: dormant reset, recent left alone, purchased balance untouched | passed |
| Crontab registration | passed |
| Import against a SQLite database built with the source's own schema: balances, microsecond timestamps, the null latch, the `-1` sentinel, a duplicate charge, and a repeated run | passed |
| Import against the real production database | **not verified** — no such file in this environment |

### Slice 5 — deployment and agent documentation (done)

Not a product slice: what the previous four made necessary in the image and in
the project's own instructions.

- **`ffmpeg` added to the runtime image.** The source's Dockerfile installed
  it; the generated one did not, so video notes would have failed in production
  with an ffmpeg-not-found error while passing every test on a developer
  machine.
- **ex_gram conventions written into `AGENTS.md`**, as the bootstrap handoff
  said they would have to be: the Req adapter, the token-passing convention,
  clause ordering, the update shapes, the rich-message hack, and how to test
  against the ex_gram test adapter. ex_gram ships no usage rules of its own.

**Verification**

| Step | Result |
|---|---|
| `MIX_ENV=prod mix compile --force --warnings-as-errors` | passed |
| `MIX_ENV=prod mix assets.deploy` | passed, client and SSR bundles |
| `MIX_ENV=prod mix release --overwrite` | passed |
| `docker build` | passed |
| `ffmpeg -version` inside the runner image | passed, ffmpeg 7.1.5 |
| `/app/bin/migrate` against `postgres:17-alpine` | passed, all three migrations |
| Running container: `/` 200, `/admin` 401 without credentials, 200 with, `/oban` 200 with | passed |
| `Settings.telegram_token()` in the container with no token set | passed, `nil` — the bot stays stopped and the endpoint serves alone |
| Container logs | passed, no errors |

Containers, the image and the network created for this were removed afterwards.

### Slice 6 — the unknown-command reply (done)

Scenario 3.7's last line, deferred in slice 1 as "forwarding is out of scope"
and no longer out of scope. Plain text in a private chat now gets
`UNKNOWN_COMMAND_MESSAGE`, which exists so that someone replying to a forwarded
transcription learns their reply will not reach the person who recorded it.

An undeclared command counts as text, as it did in the source: ex_gram reports
a declared command with an atom name and an undeclared one with a string, and
both clauses answer. Verified through the real dispatcher.

## 17. What is left

Everything in sections 1-10 that the source does is now implemented, with one
deliberate exception and one product decision:

- **`/model` was not ported** (defect D4: it exposes engine configuration to
  every user). AshAdmin covers the operator's need. Confirm before release.
- **The LiveVue operator console is parked.** AshAdmin plus Oban Web behind
  basic auth is the console; section 12's `/subscribers`, `/payments` and
  `/engines` screens are a proposal, not planned work.

The remaining risk is entirely in what cannot be exercised without credentials:
Telegram's acceptance of the Bot API 10.2 rich-message payload, a real
transcription engine, and a real Stars purchase. See the handoff's open
questions.
