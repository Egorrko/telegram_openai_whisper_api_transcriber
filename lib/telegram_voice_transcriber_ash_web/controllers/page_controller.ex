defmodule TelegramVoiceTranscriberAshWeb.PageController do
  use TelegramVoiceTranscriberAshWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
