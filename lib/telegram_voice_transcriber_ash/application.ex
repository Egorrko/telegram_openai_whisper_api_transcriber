defmodule TelegramVoiceTranscriberAsh.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    children = [
      TelegramVoiceTranscriberAshWeb.Telemetry,
      TelegramVoiceTranscriberAsh.Repo,
      {DNSCluster,
       query: Application.get_env(:telegram_voice_transcriber_ash, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:telegram_voice_transcriber_ash, :ash_domains),
         Application.fetch_env!(:telegram_voice_transcriber_ash, Oban)
       )},
      {Phoenix.PubSub, name: TelegramVoiceTranscriberAsh.PubSub},
      # Start a worker by calling: TelegramVoiceTranscriberAsh.Worker.start_link(arg)
      # {TelegramVoiceTranscriberAsh.Worker, arg},
      # Start to serve requests, typically the last entry
      TelegramVoiceTranscriberAshWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :telegram_voice_transcriber_ash]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TelegramVoiceTranscriberAsh.Supervisor]

    children =
      children ++
        if(Application.get_env(:live_vue, :ssr_module) == LiveVue.SSR.QuickBEAM,
          do: [LiveVue.SSR.QuickBEAM],
          else: []
        )

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TelegramVoiceTranscriberAshWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
