defmodule FerriWeb.PageController do
  use FerriWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
