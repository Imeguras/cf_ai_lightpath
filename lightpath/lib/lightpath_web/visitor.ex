defmodule LightpathWeb.Visitor do
  @moduledoc """
  Gives each browser an anonymous id, kept in the (signed) session cookie
  under `"visitor"`: 32 lowercase hex characters, made once and then reused.
  It is the JWT subject for the Worker, which rate-limits by it, and names
  the browser's chat conversations. It identifies nobody.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Plug.Conn.get_session(conn, "visitor") do
      id when is_binary(id) ->
        conn

      _ ->
        Plug.Conn.put_session(
          conn,
          "visitor",
          Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        )
    end
  end
end
