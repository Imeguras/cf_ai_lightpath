defmodule CockpitWeb.PageController do
  use CockpitWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
