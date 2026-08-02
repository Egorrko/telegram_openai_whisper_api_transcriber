defmodule TelegramVoiceTranscriberAsh.Transcribing.Engines.GeminiTest do
  @moduledoc """
  Both request shapes, against a stand-in for Google: small audio inline, large
  audio through the Files API.
  """

  use ExUnit.Case, async: false

  alias TelegramVoiceTranscriberAsh.Transcribing.Engines.Gemini

  @answer ~s({"candidates":[{"content":{"parts":[{"text":"расшифровка"}]}}]})

  defmodule FakeGemini do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      send(:gemini_test, {:called, conn.method, conn.request_path, headers(conn), body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> respond(body)
    end

    defp headers(conn), do: Map.new(conn.req_headers)

    defp respond(%{request_path: "/upload/v1beta/files"} = conn, _body) do
      case Plug.Conn.get_req_header(conn, "x-goog-upload-command") do
        ["start"] ->
          conn
          |> Plug.Conn.put_resp_header("x-goog-upload-url", upload_url(conn))
          |> Plug.Conn.send_resp(200, "{}")

        _ ->
          state =
            Application.get_env(:telegram_voice_transcriber_ash, :fake_gemini_state, "ACTIVE")

          file = ~s({"name":"files/abc","uri":"https://gemini/files/abc","state":"#{state}"})
          Plug.Conn.send_resp(conn, 200, ~s({"file":#{file}}))
      end
    end

    defp respond(%{request_path: "/v1beta/files/abc", method: "GET"} = conn, _body) do
      Plug.Conn.send_resp(conn, 200, ~s({"name":"files/abc","uri":"u","state":"ACTIVE"}))
    end

    defp respond(%{request_path: "/v1beta/files/abc", method: "DELETE"} = conn, _body) do
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    defp respond(conn, _body) do
      Plug.Conn.send_resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"text":"расшифровка"}]}}]})
      )
    end

    defp upload_url(conn) do
      "http://localhost:#{conn.port}/upload/v1beta/files?upload_id=1"
    end
  end

  setup do
    Process.register(self(), :gemini_test)

    {:ok, listener} = Bandit.start_link(plug: FakeGemini, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    put_env(:gemini_base_url, "http://localhost:#{port}")
    put_env(:gemini_api_key, "test-key")

    :ok
  end

  defp put_env(key, value) do
    Application.put_env(:telegram_voice_transcriber_ash, key, value)
    on_exit(fn -> Application.delete_env(:telegram_voice_transcriber_ash, key) end)
  end

  defp calls do
    Enum.reverse(drain([]))
  end

  defp drain(acc) do
    receive do
      {:called, method, path, headers, body} -> drain([{method, path, headers, body} | acc])
    after
      0 -> acc
    end
  end

  test "no API key is an error, not a crash" do
    Application.delete_env(:telegram_voice_transcriber_ash, :gemini_api_key)

    assert {:error, message} = Gemini.transcribe("audio", "audio/ogg", "gemini-3.5-flash-lite")
    assert message =~ "GEMINI_API_KEY"
  end

  test "small audio is sent inline, in a single request" do
    assert {:ok, "расшифровка"} =
             Gemini.transcribe("small audio", "audio/ogg", "gemini-3.5-flash-lite")

    assert [{"POST", path, headers, body}] = calls()
    assert path == "/v1beta/models/gemini-3.5-flash-lite:generateContent"
    assert headers["x-goog-api-key"] == "test-key"

    decoded = Jason.decode!(body)

    assert [%{"text" => prompt}, %{"inline_data" => inline}] =
             get_in(decoded, ["contents", Access.at(0), "parts"])

    assert prompt =~ "transcription engine"
    assert Base.decode64!(inline["data"]) == "small audio"
    assert decoded["generationConfig"]["response_mime_type"] == "application/json"
  end

  test "large audio is uploaded first and the upload is cleaned up afterwards" do
    audio = :binary.copy("x", 11 * 1024 * 1024)

    assert {:ok, "расшифровка"} = Gemini.transcribe(audio, "audio/mpeg", "gemini-3.5-flash-lite")

    assert [start, upload, generate, delete] = calls()

    {"POST", "/upload/v1beta/files", start_headers, _} = start
    assert start_headers["x-goog-upload-command"] == "start"

    assert start_headers["x-goog-upload-header-content-length"] ==
             Integer.to_string(byte_size(audio))

    assert start_headers["x-goog-upload-header-content-type"] == "audio/mpeg"

    {"POST", "/upload/v1beta/files", upload_headers, sent} = upload
    assert upload_headers["x-goog-upload-command"] == "upload, finalize"
    assert sent == audio

    {"POST", "/v1beta/models/gemini-3.5-flash-lite:generateContent", _, generate_body} = generate
    parts = get_in(Jason.decode!(generate_body), ["contents", Access.at(0), "parts"])
    assert [_prompt, %{"file_data" => %{"file_uri" => "https://gemini/files/abc"}}] = parts

    assert {"DELETE", "/v1beta/files/abc", _, _} = delete
  end

  test "an upload that is still processing is waited for" do
    put_env(:fake_gemini_state, "PROCESSING")
    audio = :binary.copy("x", 11 * 1024 * 1024)

    assert {:ok, "расшифровка"} = Gemini.transcribe(audio, "audio/mpeg", "gemini-3.5-flash-lite")

    assert Enum.any?(calls(), &match?({"GET", "/v1beta/files/abc", _, _}, &1))
  end

  test "an unexpected answer is reported rather than swallowed" do
    put_env(:gemini_base_url, "http://localhost:1")

    assert {:error, %Req.TransportError{}} =
             Gemini.transcribe("small", "audio/ogg", "gemini-3.5-flash-lite")
  end

  test "the answer is a JSON body the parser can read" do
    assert {:ok, text} = Gemini.transcribe("small", "audio/ogg", "gemini-3.5-flash-lite")
    assert text == "расшифровка"
    assert @answer =~ text
  end
end
