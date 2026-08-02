# TelegramVoiceTranscriberAsh

Phoenix + Ash + LiveVue replatforming target for the Django Telegram voice
transcription bot.

**Implemented so far: the private-chat product.** A user sends a voice message
or audio file, the bot edits its reply in place into the transcript, and the
audio's duration is charged against the account's balance. `/start`, `/stats`,
`/payment N` (Telegram Stars) and `/paysupport` work. Group transcription,
forwarding to the operator and video notes are not built yet.

The product analysis, the slice log and the open questions live in
[`docs/REPLATFORM_ANALYSIS.md`](docs/REPLATFORM_ANALYSIS.md) and
[`docs/BOOTSTRAP_HANDOFF.md`](docs/BOOTSTRAP_HANDOFF.md).

The bot starts only when `TELEGRAM_TOKEN` is set; without it the web endpoint
runs alone. See [`.env.example`](.env.example) for every variable.

## Development

Requires Elixir 1.20+/OTP 29, Node 20.19+ (Vite 8), and a reachable PostgreSQL.

```bash
mix setup          # deps, database, npm install, asset build, seeds
mix phx.server     # http://localhost:4000
```

`mix setup` must run before the first `mix test`: the root layout reads the Vite
manifest at `priv/static/.vite/manifest.json`, which only exists after
`mix assets.build`.

The operator console is AshAdmin plus Oban Web, in every environment, behind
HTTP basic auth. In development the credentials are `operator` / `operator`; in
production they come from `OPERATOR_USERNAME` / `OPERATOR_PASSWORD`, and both
routes answer 404 while those are unset.

| Path | What | Where |
|---|---|---|
| `/admin` | AshAdmin — accounts, balances, usage log | all environments, basic auth |
| `/oban` | Oban Web | all environments, basic auth |
| `/dev/vue_demo` | LiveVue round-trip demo | `:dev_routes` only |
| `/dev/dashboard` | Phoenix LiveDashboard | `:dev_routes` only |
| `/dev/mailbox` | Swoosh mailbox preview | `:dev_routes` only |

## Assets

The UI is built with [LiveVue](https://hexdocs.pm/live_vue), bundled by Vite
through `phoenix_vite`. Unlike a stock Phoenix app, `package.json` and
`node_modules` live at the **project root**, not in `assets/`, because LiveVue
resolves `live_vue`, `phoenix` and `phoenix_vite` through `file:./deps/*`.
Vite itself runs with `assets/` as its working directory.

```bash
mix assets.setup   # npm install, at the project root
mix assets.build   # client bundle + SSR bundle (priv/static/server.mjs)
```

Server-side rendering uses `LiveVue.SSR.QuickBEAM` in production, so the runtime
image needs no Node.

## Tests and checks

```bash
mix test
mix precommit     # compile --warnings-as-errors, deps.unlock --unused, format, test
```

## Production

Configuration is read from the environment at boot; see
[`.env.example`](.env.example). `DATABASE_URL`, `SECRET_KEY_BASE`,
`TOKEN_SIGNING_SECRET` and `PHX_HOST` are required — the release refuses to
start without them.

```bash
cp .env.example .env    # then fill it in
docker compose up -d --build
docker compose logs -f bot
```

Compose brings up Postgres and the bot; migrations run on every boot, which is
safe because they are idempotent. `DATABASE_URL` is supplied by compose, so the
one in `.env` is ignored there. The console is published on `127.0.0.1:4000`
only — reach it over an SSH tunnel, or drop the port mapping entirely.

**Only one process may poll a given bot token.** Stop the old deployment before
starting this one, or test against a second bot from @BotFather.

The generated Dockerfile was adjusted for this stack: the builder installs
`nodejs`/`npm`, `npm install` runs at the project root after `mix deps.get`,
and the runner image carries `ffmpeg`, which video notes need.

## Agent documentation

`AGENTS.md` carries the Elixir and OTP rules. Framework rules are packaged as
skills under `.claude/skills/`:

- `ash-framework` — Ash, AshPostgres, AshPhoenix, AshOban, AshAuthentication
- `phoenix-livevue-web` — Phoenix, LiveView, LiveVue

Both are generated from the dependencies' own `usage-rules.md` files. After
adding or removing a dependency, re-run:

```bash
mix usage_rules.sync
```

The `:usage_rules` key in `mix.exs` is the source of truth for what gets synced.
