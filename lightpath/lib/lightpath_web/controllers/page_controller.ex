defmodule LightpathWeb.PageController do
  use LightpathWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
