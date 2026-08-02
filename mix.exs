defmodule TelegramVoiceTranscriberAsh.MixProject do
  use Mix.Project

  def project do
    [
      app: :telegram_voice_transcriber_ash,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules()
    ]
  end

  # Agent-facing documentation, synced with `mix usage_rules.sync`.
  # Language-level rules are inlined into AGENTS.md because they always apply;
  # framework rules live in skills so they load only when relevant.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: ["usage_rules:elixir", "usage_rules:otp"],
      skills: [
        location: ".claude/skills",
        package_skills: [:ash, ~r/^ash_/, :phoenix, ~r/^phoenix_/, :live_vue],
        build: [
          "ash-framework": [
            description:
              "Use when working with Ash Framework or any of its extensions. Always consult this before changing domains, resources, actions, policies, or migrations.",
            usage_rules: [:ash, ~r/^ash_/, :spark, :reactor]
          ],
          "phoenix-livevue-web": [
            description:
              "Use when working on the web layer: Phoenix, LiveView, and the LiveVue component layer that renders every screen in this project.",
            usage_rules: [:phoenix, ~r/^phoenix_/, :live_vue]
          ]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {TelegramVoiceTranscriberAsh.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:finch, "~> 0.21"},
      {:sentry, "~> 13.0"},
      {:ex_gram, "~> 0.67"},
      {:quickbeam, "~> 0.8"},
      {:live_vue, "~> 1.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_admin, "~> 1.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      # Overridden past ex_gram's {:req, "~> 0.5.0"} bound: every req 0.5.x is
      # affected by EEF-CVE-2026-49755 (HIGH, decompression-bomb DoS), fixed in
      # 0.6.1. Drop the override once ex_gram widens its constraint.
      {:req, "~> 0.7", override: true},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["phoenix_vite.npm assets install"],
      "assets.build": [
        "phoenix_vite.npm vite build --manifest --ssrManifest --emptyOutDir true",
        "phoenix_vite.npm vite build --emptyOutDir false --ssr js/server.js --outDir ../priv/static"
      ],
      "assets.deploy": [
        "assets.build"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
