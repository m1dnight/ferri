defmodule FerriWeb.PageController do
  use FerriWeb, :controller

  def home(conn, _params) do
    render(conn, :home, version: Application.spec(:ferri, :vsn) |> to_string())
  end
end
