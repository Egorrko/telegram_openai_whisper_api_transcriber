import Config

# The bot is exercised by calling its modules, never by polling Telegram.
config :telegram_voice_transcriber_ash,
  telegram_token: "test-token",
  start_bot: false,
  # No point waiting out the retry backoff in tests.
  retry_delay_ms: 0

config :ex_gram, adapter: ExGram.Adapter.Test, token: "test-token"

config :telegram_voice_transcriber_ash, Oban, testing: :manual
config :telegram_voice_transcriber_ash, token_signing_secret: "6BBV68Z4nVedg2xa7JClRjIL/3JBGf0M"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAsh.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "telegram_voice_transcriber_ash_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UCiJugCNYqcd3yraf5eLITVs1jTjWRWPM3yjAepSVyUeMSDbT6wq95di805/Orkf",
  server: false

# In test we don't send emails
config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAsh.Mailer,
  adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
