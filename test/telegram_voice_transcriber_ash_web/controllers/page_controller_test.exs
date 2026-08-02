defmodule TelegramVoiceTranscriberAshWeb.PageControllerTest do
  use TelegramVoiceTranscriberAshWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "successfully created a LiveVue app with Phoenix"
  end
end
