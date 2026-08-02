{:ok, _} = ExGram.Adapter.Test.start_link()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(TelegramVoiceTranscriberAsh.Repo, :manual)
