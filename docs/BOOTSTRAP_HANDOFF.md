# Bootstrap handoff

## Paths and revisions

- Source path: `/home/egorrko/code/elixir/tg_voice_showcase/telegram_voice_transciber`
- Source revision: `1f8d7d1` (Merge pull request #4 from
  Egorrko/feature/expandable-blockquote-transcription); working tree clean at analysis time
- Target path: `/home/egorrko/code/elixir/tg_voice_showcase/telegram_voice_transcriber_ash`
- Target revision (the bootstrap commit; this file lands in the next one): `498ece6`
  - preceded by `dae0844`, the generator's own initial commit

The target application name corrects a typo: the source directory is
`telegram_voice_transciber`, while its `pyproject.toml` spells it `transcriber`. The target
uses `telegram_voice_transcriber_ash`.

## Toolchain

- Elixir 1.20.2, Erlang/OTP 29 (erts-17.0.2)
- Mix 1.20.2
- Node v26.2.0, npm 11.16.0
- git 2.43.0
- Docker available: yes
- PostgreSQL available: yes (psql 17.10 on the host; the container verification used
  `postgres:17-alpine`)
- Verification steps blocked by missing tools: **none**. Every step listed below was
  actually executed.

## Ecosystem catalog

- Generated at: 2026-08-02T13:38:56.713Z
- Ash HQ commit: `d90e367d40ed33201cb4d1bb2ea23b9b7d7da458`
- Installer grammar drift reported: no. The grammar in `ASH_CURATED.md` was confirmed against
  `mix help igniter.new` before use. One undocumented behavior worth knowing: `igniter.new`
  now initializes a git repository and commits automatically unless `--no-git` is passed.
- Uncurated packages researched: `ex_gram`, `telegex` (rejected — last release 18 September
  2024), `sentry`, `req`.

## Selected target stack

| Package | Version | Source capability it supports |
|---|---|---|
| `ash` | 3.31.0 | Application layer |
| `ash_phoenix` | 2.3.24 | Web layer |
| `ash_postgres` | 2.11.0 | Replaces Django ORM + SQLite (`src/bot/models.py`) |
| `ash_authentication` | 4.14.1 | Operator login; replaces `django.contrib.auth` guarding `/admin/` |
| `ash_authentication_phoenix` | 2.17.2 | Sign-in routes for the above |
| `ash_admin` | 1.2.0 | Operator resource UI; replaces the (inert) Django admin |
| `ash_oban` | 0.8.11 | Durable monthly free-allowance reset and transcription retries |
| `oban_web` | 2.12.6 | Job observability |
| `live_vue` | 1.2.2 | The whole UI layer, per `STACK_POLICY.md` |
| `usage_rules` | 1.2.7 | Project-local agent rules |
| `ex_gram` | 0.67.0 | Telegram Bot API client; replaces `aiogram` |
| `sentry` | 13.3.0 | Replaces `sentry-sdk` |
| `req` | 0.7.2 | Transcription providers + the Bot API 10.2 rich-message calls |
| `phoenix` | 1.8.9 | — |
| `phoenix_vite` | 0.5.0 | Asset pipeline behind LiveVue |

Rejected capabilities and the reasoning behind each are in
[`REPLATFORM_ANALYSIS.md`](REPLATFORM_ANALYSIS.md) section 11.

Note the resolved auth versions: the Ash HQ catalog advertises `ash_authentication`
5.0.0-rc.12 and `ash_authentication_phoenix` 3.0.0-rc.9, but the installer wrote `~> 4.0` /
`~> 2.0` and Hex resolved the stable 4.14.1 / 2.17.2. **No release candidate is in the lock
file.**

## Exact bootstrap command

```bash
# archives
mix archive.install hex igniter_new --force
mix archive.install hex phx_new 1.8.9 --force

# project creation (postgres is the phx.new default, so no --with-args)
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

# from the target root
mix igniter.install live_vue --yes
mix igniter.install ex_gram sentry --yes
mix usage_rules.sync --yes
```

`req` needed no installer — `phx.new` adds it. `ex_gram` ships no Igniter installer.

## Setup performed

No authentication providers were configured and no external integration was wired: this
bootstrap deliberately contains **no product behavior**. What was done beyond running the
installers:

**Installer defects fixed.** Each of these broke the bootstrap and each fix is in the commit.

1. **`phoenix_vite` 0.5.0 crashed the LiveVue installer.** `has_tailwind?/1` calls
   `Igniter.exists?/2` (filesystem) then `Rewrite.source/2` (in-memory source set), so it
   raised `%Rewrite.Error{reason: :nosource, path: "assets/css/app.css"}`. New in 0.5.0;
   0.4.3 has no such function. Worked around by adding the missing
   `Igniter.include_existing_file/2` to the dependency, running the installer, then restoring
   the dependency with `mix deps.clean phoenix_vite`. Without it, `vite.config.mjs` silently
   loses the Tailwind plugin and drops `css/app.css` from the rollup input — verified present
   in the generated file.
2. **`req` pinned to a vulnerable version.** `ex_gram` declares `{:req, "~> 0.5.0"}` and Hex
   enforces it even though it is optional. Every req 0.5.x is affected by
   **EEF-CVE-2026-49755 (HIGH)** — decompression-bomb DoS via auto-decoded compressed bodies —
   fixed in 0.6.1. Since this product downloads attacker-supplied audio, that is on the attack
   path. Resolved with `{:req, "~> 0.7", override: true}` in `mix.exs`.
3. **`phoenix_vite`'s npm profile pointed at the wrong directory.** `config/config.exs` had
   `assets: [args: [], cd: __DIR__]`, i.e. `config/`. LiveVue puts `package.json` at the
   project root and resolves `live_vue`/`phoenix`/`phoenix_vite` through `file:./deps/*`.
   Changed to `Path.expand("..", __DIR__)`. This only surfaced in the Docker build, because
   the LiveVue installer runs `npm install` itself.
4. **The generated Dockerfile assumed esbuild.** Added `nodejs`/`npm` to the builder stage,
   and moved `COPY package.json package-lock.json ./` before `mix assets.setup` so npm runs
   at the project root after deps are fetched.
5. **`.dockerignore` missed the root `node_modules`** (356 MB of build context, and it would
   shadow the container's own install). Only `/assets/node_modules/` was excluded.
6. **Sentry shipped a literal placeholder that crashed the release.** `config/prod.exs` had
   `dsn: "<your_dsn>"`, which fails `Sentry.Config.validate!/1` at boot — the container
   would not start. The DSN now comes from `SENTRY_DSN` in `runtime.exs`, and an unset
   variable leaves Sentry inert, matching the source product's `if settings.SENTRY_DSN:`.
7. **The landing page warned on every prod compile.** It linked `~p"/dev/vue_demo"`, a
   verified route that only exists under `:dev_routes`. The link is now conditional and uses
   a plain href.
8. **The generated page controller test asserted on replaced copy.** It looked for
   "Peace of mind from prototype to production", which the LiveVue installer had overwritten.

**Runtime environment.** `.env.example` documents every variable. Four are required by the
release and it refuses to boot without them: `DATABASE_URL`, `SECRET_KEY_BASE`,
`TOKEN_SIGNING_SECRET`, `PHX_HOST`. Optional: `PORT`, `POOL_SIZE`, `ECTO_IPV6`,
`DNS_CLUSTER_QUERY`, `SENTRY_DSN`. The source product's variables (Telegram token, engine
keys, quota settings, chat allow-lists, proxy) are carried over in a clearly marked section
as **not yet read by any code**.

**Frontend.** LiveVue with Vite. `package.json` and `node_modules` live at the project root,
not under `assets/` — Vite runs with `assets/` as its working directory. Production SSR uses
`LiveVue.SSR.QuickBEAM`, so the runtime image needs no Node.

## UsageRules and skills

- Main generated rules file: `AGENTS.md` (10 KB). Configured via the `:usage_rules` key in
  `mix.exs`, which is the source of truth for `mix usage_rules.sync`.
- Inlined into `AGENTS.md`: `usage_rules:elixir`, `usage_rules:otp` — language-level rules
  that always apply.
- Generated skill directories: `.claude/skills/ash-framework`,
  `.claude/skills/phoenix-livevue-web` (50 rule files total).
- Packages contributing rules, each cross-checked against `mix.lock`: `ash`,
  `ash_authentication`, `ash_oban`, `ash_phoenix`, `ash_postgres`, `live_vue`, `phoenix`.
- Composed project skills:
  - `ash-framework` — `[:ash, ~r/^ash_/, :spark, :reactor]`
  - `phoenix-livevue-web` — `[:phoenix, ~r/^phoenix_/, :live_vue]`
- Package-provided skills: **none exist**. No installed dependency ships a `skills/`
  directory, so `package_skills` produced nothing. The option is configured so that future
  dependencies are picked up automatically.
- `ash_admin`, `oban_web`, `ash_authentication_phoenix`, `ex_gram` and `sentry` ship no usage
  rules. For `ex_gram` in particular, conventions have to be hand-written as the bot layer is
  built.

## Verification performed

Every line below was executed. Nothing is marked passed on the strength of having been
skipped.

| Step | Command | Result |
|---|---|---|
| Dependency fetch | `mix deps.get` | **passed** |
| Compilation (dev) | `mix compile --force --warnings-as-errors` | **passed**, no warnings |
| Compilation (prod) | `MIX_ENV=prod mix compile --force --warnings-as-errors` | **passed**, no warnings |
| Formatting | `mix format --check-formatted` | **passed** |
| Database setup and migrations | `mix ash.reset` | **passed** (Oban + citext + auth tables) |
| Tests | `mix test` | **passed**, 5/5 |
| Full precommit | `mix precommit` | **passed** |
| Development boot and HTTP | `mix phx.server`, `curl localhost:4000` | **passed**, 200; `/dev/vue_demo` 200 (LiveVue round trip); `/admin` 200 (AshAdmin) |
| Production asset build | `MIX_ENV=prod mix assets.deploy` | **passed**, client + SSR bundles, daisyUI 5.7.14 processed |
| Release generation | `mix phx.gen.release --docker` | **passed** |
| OTP release build | `MIX_ENV=prod mix release --overwrite` | **passed** |
| Docker image build | `docker build` | **passed** (after fixes 3–5 above) |
| Release migrations from the image | `docker run … /app/bin/migrate` | **passed** against `postgres:17-alpine` |
| Running container HTTP | `curl localhost:4001` | **passed**, 200; digested JS and CSS both 200 |
| Production route gating | `curl localhost:4001/admin` | **passed**, 404 as intended |
| ex_gram Req adapter | `ExGram.get_me/1` against the live Bot API | **passed**, correct `%ExGram.Error{code: 401}`; multipart encoding checked separately |
| `.env.example` and startup docs | — | **written** (`.env.example`, `README.md`) |

Not verified, and deliberately so: anything requiring real provider credentials — sending a
Telegram message, calling Gemini/OpenAI/ElevenLabs, or rendering a Bot API 10.2 rich message.
Those need live secrets and are the first slice's job.

Docker containers and the network created for verification were removed afterwards.

## First vertical slice

**Transcribe a voice message in a private chat, end to end, metered.**

Scenario 3.1 of the analysis, with the group, forwarding and payment paths excluded. It is the
smallest slice that exercises the bot transport, the metering ledger, an external engine, the
Bot API 10.2 rich-message gap, and the failure path — every identified risk.

- **User-visible start**: a user sends a voice message to the bot in a private chat.
- **User-visible finish**: the bot's reply message has been edited in place into the transcript
  — a block quotation when short, an expandable details block when long — and `/stats` reports
  a balance reduced by the audio duration.
- **Resources and actions**: `Metering.Subscriber` with `:find_or_register`, `:reserve` and
  `:debit`; `Metering.TranscriptionLog` with `:record`.
- **Authorization**: none at the bot layer beyond the source's own filters — identity is the
  hashed Telegram ID. The operator console is not part of this slice.
- **UI path**: none. This slice is bot-only, deliberately: the LiveVue console has no source
  behavior to port and must not block the product's actual function.
- **Tests**:
  - a pinned SHA-256 digest test — `sha256(str(telegram_user_id)).hexdigest()` must stay
    bit-identical or every existing balance is silently orphaned;
  - a port of `src/bot/tests/send_results_tests.py` against `Transcribing.ResponseParser`:
    valid JSON, malformed-JSON salvage, plain text, the 200-character threshold, summary
    fallback order, chunk boundaries;
  - a port of `transcription_tests.py` and `edge_cases_tests.py` against `:reserve` / `:debit`:
    free, purchased, mixed, exceeded, warning latch, 30-day reset, exact-boundary usage;
  - a **new** concurrency test that the source would fail: two simultaneous
    `:reserve` + `:debit` cycles against one subscriber must not overdraw the balance;
  - one engine test against a stubbed `Transcribing.Engine`.
- **Verification**: `mix precommit`, plus a manual round trip against a real bot token with
  `GEMINI_API_KEY` set, confirming both the short and long rendering paths.
- **Scope boundary — explicitly out**: group handlers, reply-mention handling,
  forward-to-admin, Telegram Stars payments, the LiveVue console, AshAdmin, Oban Web, the
  monthly-reset cron, the local Bot API server, ffmpeg video-note conversion, and the SQLite
  data import.

## Open questions

1. **Rich messages are the top technical risk.** ex_gram 0.67.0 tracks Bot API 10.1, whose
   `InputRichMessage` carries `html`/`markdown`. The source depends on the `blocks` array
   added in Bot API 10.2 (14 July 2026). Plan: ex_gram for polling, dispatch, file download
   and ordinary sends; hand-rolled JSON over Req for `sendRichMessage` and `editMessageText`
   with `rich_message`, isolated in one module. Verify against a live bot early.
2. **Is the LiveVue operator console wanted at all?** `STACK_POLICY.md` mandates LiveVue for
   the whole UI, but the source has no UI — the console is a proposal, not a migration. It may
   be over-scoped for a single-operator bot; the honest alternative is AshAdmin plus Oban Web
   and nothing else. Product decision.
3. **Should transcription become a durable Oban job?** It fixes the stranded-"Распознаю..."
   failure and enables real backoff, but changes the latency profile and moves progress edits
   into a worker. Recommended, but it is a behavior change, not a port.
4. **Payment idempotency and `drop_pending_updates`.** The source sets
   `drop_pending_updates=True`, discarding payments that arrived while the bot was down, and
   `Payment.payment_id` is not unique. Fixing this means dropping the flag and making the
   credit idempotent on `charge_id`. Confirm no operational reason required that flag.
5. **The four undocumented `PROXY_*` variables** are required by the source's
   `docker-compose.yml` but absent from its `.env.example`. Confirm whether the proxy is still
   needed.
6. **Should `/model` survive?** It leaks engine configuration to every user. The console's
   `/engines` screen covers the operator need.
7. **Data import timing.** A one-shot SQLite → Postgres script is trivial but must run against
   a stopped bot to avoid split-brain balances. Confirm a maintenance window.
8. **The `req` override is load-bearing.** `{:req, "~> 0.7", override: true}` keeps a HIGH
   CVE out of the tree while still using ex_gram. Do not "clean it up". Remove it only when
   ex_gram widens its constraint, and re-run the adapter smoke test when you do.
9. **Fallback if the 10.2 path proves painful**: reconsider ex_gram entirely and write a small
   Bot API client over Req. Only the polling loop and update dispatch would need replacing.

Defects in the source that the target should fix rather than reproduce — non-atomic balance
updates, the non-unique payment charge ID, the `-1` sentinel in the transcription log, the
unused `transcription_time` argument, the never-cleared warning latch — are catalogued in
[`REPLATFORM_ANALYSIS.md`](REPLATFORM_ANALYSIS.md) section 5.

## Continuing from here

Start a new Claude Code session from this repository root, so the generated
project instructions and skills load as context, and run:

```text
/next-slice
```

It reads this handoff and the analysis, implements the first vertical slice end
to end, verifies it, and commits. Run it again for each following slice, or name
one explicitly with `/next-slice <slice>`.
