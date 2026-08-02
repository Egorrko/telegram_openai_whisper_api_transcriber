import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/telegram_voice_transcriber_ash start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint, server: true
end

config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---------------------------------------------------------------------------
# The bot. Every variable below is the one the source Django bot used, so an
# existing .env keeps working. Unset TELEGRAM_TOKEN leaves the bot stopped.
#
# Skipped under :test, where config/test.exs owns these values.
# ---------------------------------------------------------------------------
if config_env() != :test do
  minutes = fn name, default ->
    String.to_integer(System.get_env(name) || default) * 60
  end

  # Short chat IDs are turned into supergroup IDs exactly as the source did.
  # Surprising, but it is the existing operational contract: every deployed
  # allow-list is written in the short form.
  chat_ids = fn name ->
    (System.get_env(name) || "")
    |> String.split(",", trim: true)
    |> Enum.map(&(-(1_000_000_000_000 + String.to_integer(String.trim(&1)))))
  end

  config :telegram_voice_transcriber_ash,
    telegram_token: System.get_env("TELEGRAM_TOKEN"),
    bot_username: System.get_env("BOT_USERNAME"),
    allowed_chat_ids: chat_ids.("ALLOWED_CHAT_IDS"),
    forward_chat_ids: chat_ids.("FORWARD_CHAT_IDS"),
    admin_id: System.get_env("ADMIN_ID") && String.to_integer(System.get_env("ADMIN_ID")),
    available_seconds: minutes.("AVAILABLE_MINUTES", "30"),
    left_warning_seconds: minutes.("LEFT_WARNING_MINUTES", "10"),
    currency_rate_seconds: minutes.("CURRENCY_RATE", "10"),
    support_username: System.get_env("SUPPORT_USERNAME"),
    max_retries: String.to_integer(System.get_env("MAX_RETRIES") || "3"),
    retry_delay_ms: String.to_integer(System.get_env("RETRY_DELAY") || "1") * 1000,
    transcription_engine: System.get_env("TRANSCRIPTION_ENGINE") || "gemini-3.5-flash-lite",
    fallback_transcription_engine: System.get_env("FALLBACK_TRANSCRIPTION_ENGINE"),
    gemini_api_key: System.get_env("GEMINI_API_KEY"),
    openai_api_key: System.get_env("OPENAI_API_KEY"),
    elevenlabs_api_key: System.get_env("ELEVENLABS_API_KEY")

  # A self-hosted telegram-bot-api server lifts the 20 MB download cap.
  if base_url = System.get_env("TELEGRAM_BOT_API_URL") do
    config :ex_gram, base_url: base_url
  end

  # Outbound proxy. The source injected ALL_PROXY/HTTP_PROXY/HTTPS_PROXY and let
  # httpx read them; nothing in the Elixir HTTP stack does, so the same four
  # variables are turned into a Finch pool every outbound call uses.
  if proxy_host = System.get_env("PROXY_HOST") do
    proxy = [
      host: proxy_host,
      port: String.to_integer(System.get_env("PROXY_PORT") || "8080"),
      username: System.get_env("PROXY_USERNAME"),
      password: System.get_env("PROXY_PASSWORD")
    ]

    config :telegram_voice_transcriber_ash, :proxy, proxy

    # Sentry runs its own Finch pool and needs telling separately.
    config :sentry, finch_pool_opts: TelegramVoiceTranscriberAsh.Proxy.pool_options(proxy)
  end

  # AshAdmin and Oban Web: unreachable (404) until credentials are configured.
  if user = System.get_env("OPERATOR_USERNAME") do
    config :telegram_voice_transcriber_ash, :operator_console_auth,
      username: user,
      password: System.get_env("OPERATOR_PASSWORD") || raise("Missing `OPERATOR_PASSWORD`!")
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/telegram_voice_transcriber_ash_web/router\.ex$"E,
        ~r"lib/telegram_voice_transcriber_ash_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAsh.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :telegram_voice_transcriber_ash, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base,
    cache_static_manifest_latest:
      PhoenixVite.cache_static_manifest_latest(:telegram_voice_transcriber_ash)

  config :telegram_voice_transcriber_ash,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # Optional: unset SENTRY_DSN leaves Sentry inert instead of failing to boot.
  config :sentry, dsn: System.get_env("SENTRY_DSN")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAshWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :telegram_voice_transcriber_ash, TelegramVoiceTranscriberAsh.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
