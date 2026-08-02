defmodule TelegramVoiceTranscriberAsh.Proxy do
  @moduledoc """
  Outbound HTTP proxy for the transcription providers, for deployments whose
  network cannot reach them directly — a VPS that Google refuses to serve, for
  one.

  The source injected `ALL_PROXY` / `HTTP_PROXY` / `HTTPS_PROXY` into the
  container and let httpx pick them up. Nothing in the Elixir HTTP stack reads
  those variables, so the same four `PROXY_*` settings are turned into Req
  connect options here.

  ## Scope: the providers and Sentry, not Telegram

  Every call this application makes itself — Gemini, OpenAI, ElevenLabs, and
  Sentry's own client — goes through the proxy. Telegram does not, because
  ex_gram's adapter hardcodes its own `connect_options` and Req refuses to
  accept both those and a pre-built proxied pool. Reaching Telegram through a
  proxy would mean vendoring that adapter.

  ponytail: that is the upgrade path if a deployment ever needs it — copy
  ex_gram's ~60-line Req adapter and add `connect_options` to it, or wait for
  ex_gram to let callers pass them. Nothing else about this module changes.
  """

  @app :telegram_voice_transcriber_ash

  @doc """
  Req options. Empty when no proxy is configured, so call sites can splice them
  in unconditionally.
  """
  def options do
    case connect_options() do
      [] -> []
      connect_options -> [connect_options: connect_options]
    end
  end

  @doc "Mint transport options: where the proxy is, and how to authenticate to it."
  def connect_options(proxy \\ config())

  def connect_options(nil), do: []

  def connect_options(proxy) do
    [proxy: {:http, proxy[:host], proxy[:port], []}] ++ auth(proxy)
  end

  @doc "The same, shaped for a Finch pool — Sentry runs its own."
  def pool_options(proxy \\ config())

  def pool_options(nil), do: []
  def pool_options(proxy), do: [conn_opts: connect_options(proxy)]

  def configured?, do: config() != nil

  defp auth(proxy) do
    case {proxy[:username], proxy[:password]} do
      {nil, _} ->
        []

      {username, password} ->
        credentials = Base.encode64("#{username}:#{password}")
        [proxy_headers: [{"proxy-authorization", "basic " <> credentials}]]
    end
  end

  defp config, do: Application.get_env(@app, :proxy)
end
