defmodule TelegramVoiceTranscriberAsh.Transcribing.EngineTest do
  @moduledoc "The retry and fallback policy (R15), against a stubbed engine."

  use ExUnit.Case, async: true

  alias TelegramVoiceTranscriberAsh.Settings
  alias TelegramVoiceTranscriberAsh.Transcribing.Engine

  defmodule Stub do
    @moduledoc false
    @behaviour TelegramVoiceTranscriberAsh.Transcribing.Engine

    @impl true
    def transcribe(_audio, _mime_type, model) do
      [{^model, {owner, script}}] = :ets.lookup(:engine_stub, model)
      send(owner, {:attempt, model})

      case Enum.at(script, :ets.update_counter(:engine_stub_calls, model, 1) - 1) do
        nil -> {:error, "exhausted"}
        :raise -> raise "движок упал"
        result -> result
      end
    end
  end

  setup do
    :ets.new(:engine_stub, [:named_table, :public])
    :ets.new(:engine_stub_calls, [:named_table, :public])
    :ok
  end

  defp stub(name, script) do
    :ets.insert(:engine_stub, {name, {self(), script}})
    :ets.insert(:engine_stub_calls, {name, 0})
    {Stub, name}
  end

  defp opts(extra), do: Keyword.merge([sleep: fn _ -> :ok end], extra)

  test "a first-attempt success calls the engine once" do
    engine = stub("primary", [{:ok, "готово"}])

    assert {:ok, "готово"} = Engine.transcribe("audio", "audio/ogg", opts(engine: engine))

    assert_received {:attempt, "primary"}
    refute_received {:attempt, "primary"}
  end

  test "the primary engine is retried, and the caller is told about each attempt" do
    engine = stub("primary", [{:error, "нет"}, {:ok, "готово"}])
    test_process = self()

    assert {:ok, "готово"} =
             Engine.transcribe(
               "audio",
               "audio/ogg",
               opts(engine: engine, on_retry: &send(test_process, {:retry, &1, &2, &3}))
             )

    assert_received {:retry, 1, max_attempts, delay}
    assert max_attempts == Settings.max_retries()
    assert delay == Settings.retry_delay_ms()
  end

  test "raising counts as a failed attempt rather than killing the pipeline" do
    engine = stub("primary", [:raise, {:ok, "готово"}])

    assert {:ok, "готово"} = Engine.transcribe("audio", "audio/ogg", opts(engine: engine))
  end

  test "the fallback engine gets one attempt after the primary is exhausted" do
    primary = stub("primary", List.duplicate({:error, "нет"}, Settings.max_retries()))
    fallback = stub("fallback", [{:ok, "запасное"}])

    assert {:ok, "запасное"} =
             Engine.transcribe("audio", "audio/ogg", opts(engine: primary, fallback: fallback))

    assert :ets.lookup_element(:engine_stub_calls, "primary", 2) == Settings.max_retries()
    assert :ets.lookup_element(:engine_stub_calls, "fallback", 2) == 1
  end

  test "both engines failing reports both errors" do
    primary = stub("primary", List.duplicate({:error, "первая беда"}, Settings.max_retries()))
    fallback = stub("fallback", [{:error, "вторая беда"}])

    assert {:error, message} =
             Engine.transcribe("audio", "audio/ogg", opts(engine: primary, fallback: fallback))

    assert message =~ "первая беда"
    assert message =~ "вторая беда"
  end

  test "an unknown engine name is reported, not raised" do
    assert {:error, message} = Engine.transcribe("audio", "audio/ogg", opts(engine: "nope"))

    assert message =~ "Invalid engine name: nope"
  end
end
