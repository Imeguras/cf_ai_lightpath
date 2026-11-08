defmodule Lightpath.ProbeClientTest do
  use ExUnit.Case, async: false

  alias Lightpath.ProbeClient

  @moduletag :tmp_dir

  # A stand-in daemon on a real unix socket.
  defmodule Stub do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, test_pid: pid, routes: routes) do
      conn = Plug.Conn.fetch_query_params(conn)
      send(pid, {:probe_request, conn.method, conn.request_path, conn.query_params})

      {status, body} =
        Map.get(routes, "#{conn.method} #{conn.request_path}", {404, ~s({"error":"not found"})})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:lightpath, :probe_socket)
    on_exit(fn -> Application.put_env(:lightpath, :probe_socket, previous) end)
    # Unix socket paths must be short (108 bytes); tmp_dir paths are long.
    sock = "/tmp/lp-test-#{System.unique_integer([:positive])}.sock"
    on_exit(fn -> File.rm(sock) end)
    %{sock: sock, tmp: tmp}
  end

  defp start(sock, routes) do
    {:ok, _} =
      Bandit.start_link(
        plug: {Stub, test_pid: self(), routes: routes},
        ip: {:local, sock},
        port: 0,
        startup_log: false
      )

    Application.put_env(:lightpath, :probe_socket, sock)
  end

  test "available? needs a configured socket that exists", %{sock: sock} do
    Application.delete_env(:lightpath, :probe_socket)
    refute ProbeClient.available?()
    Application.put_env(:lightpath, :probe_socket, sock)
    refute ProbeClient.available?()
    start(sock, %{})
    assert ProbeClient.available?()
  end

  test "without a socket every call fails without connecting" do
    Application.put_env(:lightpath, :probe_socket, "/nonexistent/x.sock")
    assert {:error, msg} = ProbeClient.status()
    assert msg =~ "LIGHTPATH_PROBE_SOCKET" or msg =~ "socket"
    assert {:error, _} = ProbeClient.probe()
    assert {:error, _} = ProbeClient.events(DateTime.utc_now())
  end

  test "probe/0 posts and returns the new set", %{sock: sock} do
    start(sock, %{"POST /probe" => {200, ~s({"set":"live-20261108T120000.000Z"})}})
    assert {:ok, "live-20261108T120000.000Z"} = ProbeClient.probe()
    assert_receive {:probe_request, "POST", "/probe", _}
  end

  test "the daemon's error comes through", %{sock: sock} do
    start(sock, %{"POST /probe" => {409, ~s({"error":"a probe run is already in progress"})}})
    assert {:error, "a probe run is already in progress"} = ProbeClient.probe()
  end

  test "status/0", %{sock: sock} do
    start(sock, %{
      "GET /status" => {200, ~s({"running":false,"last_set":"live-x","pending":["uname"]})}
    })

    assert {:ok, %{"running" => false, "last_set" => "live-x", "pending" => ["uname"]}} =
             ProbeClient.status()
  end

  test "events/1 asks from the given time", %{sock: sock} do
    start(sock, %{
      "GET /events" =>
        {200,
         ~s({"events":[{"time":"2026-11-08T19:53:37Z","kind":"package","subject":"linux","change":"upgraded","message":"linux"}]})}
    })

    assert {:ok, [%{"subject" => "linux", "kind" => "package"}]} =
             ProbeClient.events(~U[2026-11-01 00:00:00Z])

    assert_receive {:probe_request, "GET", "/events", %{"since" => "2026-11-01T00:00:00Z"}}
  end

  test "an unexpected reply is an error", %{sock: sock} do
    start(sock, %{"GET /status" => {200, "[]"}, "GET /events" => {200, ~s({"nope":1})}})
    assert {:error, _} = ProbeClient.status()
    assert {:error, _} = ProbeClient.events(DateTime.utc_now())
  end
end
