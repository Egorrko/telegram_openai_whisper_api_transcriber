defmodule TelegramVoiceTranscriberAsh.ProxyTest do
  @moduledoc """
  The outbound proxy, against a real one: a plug that answers absolute-form
  requests the way an HTTP forward proxy does.
  """

  use ExUnit.Case, async: false

  alias TelegramVoiceTranscriberAsh.Proxy
  alias TelegramVoiceTranscriberAsh.Transcribing.Engines.Gemini

  defmodule FakeProxy do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, _opts) do
      send(
        :proxy_test,
        {:proxied, conn.method, conn.request_path, conn.host,
         Plug.Conn.get_req_header(conn, "proxy-authorization")}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"candidates":[{"content":{"parts":[{"text":"ок"}]}}]}))
    end
  end

  setup do
    Process.register(self(), :proxy_test)

    on_exit(fn ->
      Application.delete_env(:telegram_voice_transcriber_ash, :proxy)
      Application.delete_env(:telegram_voice_transcriber_ash, :gemini_api_key)
    end)

    :ok
  end

  defp configure(overrides \\ []) do
    {:ok, listener} = Bandit.start_link(plug: FakeProxy, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    proxy = Keyword.merge([host: "localhost", port: port], overrides)
    Application.put_env(:telegram_voice_transcriber_ash, :proxy, proxy)

    :ok
  end

  test "no proxy configured means no options at all" do
    assert Proxy.options() == []
    assert Proxy.connect_options() == []
    assert Proxy.pool_options() == []
    refute Proxy.configured?()
  end

  test "a request goes to the proxy instead of to the target host" do
    configure()

    assert %{status: 200} = Req.get!([url: "http://example.invalid/audio"] ++ Proxy.options())

    assert_received {:proxied, "GET", "/audio", _host, []}
  end

  test "credentials are sent as proxy authorization" do
    configure(username: "bot", password: "s3cret")

    Req.get!([url: "http://example.invalid/audio"] ++ Proxy.options())

    expected = "basic " <> Base.encode64("bot:s3cret")
    assert_received {:proxied, _method, _path, _host, [^expected]}
  end

  test "an engine call is routed through the proxy — the reason the setting exists" do
    configure()
    Application.put_env(:telegram_voice_transcriber_ash, :gemini_api_key, "key")

    # The engine talks https, so this asks the proxy to open a tunnel. The fake
    # proxy cannot complete one, which is fine: what matters is that Gemini is
    # reached through it and not directly.
    Gemini.transcribe("audio", "audio/ogg", "gemini-3.5-flash-lite")

    # A CONNECT carries its target in the authority, not in the path.
    assert_received {:proxied, "CONNECT", _path, "generativelanguage.googleapis.com", []}
  end

  test "without a proxy the request has to reach the target itself" do
    assert {:error, %Req.TransportError{reason: :nxdomain}} =
             Req.get(url: "http://example.invalid/audio", retry: false)

    refute_received {:proxied, _, _, _, _}
  end

  test "the Finch shape Sentry needs carries the same transport options" do
    configure(username: "bot", password: "s3cret")

    assert [conn_opts: connect_options] = Proxy.pool_options()
    assert connect_options == Proxy.connect_options()
    assert Keyword.fetch!(connect_options, :proxy) |> elem(0) == :http
  end
end
