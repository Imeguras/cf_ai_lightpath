defmodule Lightpath.WorkerClientTest do
  # Not async: each test sets :worker_url and :jwt_secret.
  use ExUnit.Case, async: false

  alias Lightpath.Fixtures.Fixture
  alias Lightpath.WorkerClient

  @secret "client-test-secret"

  @fixture %Fixture{
    id: "zpool-status",
    argv: ["zpool", "status"],
    exit_code: 1,
    stdout: "",
    stderr: "The ZFS modules cannot be auto-loaded.",
    error: ""
  }

  # A stand-in Worker: answers each "METHOD /path" from the routes the test
  # gave it (404 otherwise) and sends every request back to the test.
  defmodule Stub do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, test_pid: pid, routes: routes) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)

      send(pid, %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_params,
        body: raw,
        content_type: Plug.Conn.get_req_header(conn, "content-type"),
        authorization: Plug.Conn.get_req_header(conn, "authorization")
      })

      {status, body} =
        Map.get(routes, "#{conn.method} #{conn.request_path}", {404, ~s({"error":"not found"})})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  defp start_stub(routes) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Stub, test_pid: self(), routes: routes},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}"
    Application.put_env(:lightpath, :worker_url, url)
    url
  end

  setup do
    previous = Map.new([:worker_url, :jwt_secret], &{&1, Application.get_env(:lightpath, &1)})
    on_exit(fn -> Enum.each(previous, fn {k, v} -> Application.put_env(:lightpath, k, v) end) end)
    Application.delete_env(:lightpath, :worker_url)
    Application.put_env(:lightpath, :jwt_secret, @secret)
    :ok
  end

  defp claims(["Bearer " <> token]) do
    [header, payload, signature] = String.split(token, ".")

    assert Base.url_decode64!(signature, padding: false) ==
             :crypto.mac(:hmac, :sha256, @secret, header <> "." <> payload)

    Base.url_decode64!(payload, padding: false) |> JSON.decode!()
  end

  describe "configuration" do
    test "available?/0 needs both the URL and the JWT secret" do
      refute WorkerClient.available?()
      Application.put_env(:lightpath, :worker_url, "http://127.0.0.1:1")
      assert WorkerClient.available?()
      Application.put_env(:lightpath, :worker_url, "")
      refute WorkerClient.available?()

      Application.put_env(:lightpath, :worker_url, "http://127.0.0.1:1")

      for missing <- [nil, ""] do
        Application.put_env(:lightpath, :jwt_secret, missing)
        refute WorkerClient.available?()
      end
    end

    test "without a URL or secret, every call fails without a request" do
      assert {:error, msg} = WorkerClient.explain(@fixture, "v")
      assert msg =~ "LIGHTPATH_WORKER_URL"
      assert {:error, msg} = WorkerClient.usage("v")
      assert msg =~ "LIGHTPATH_WORKER_URL"

      start_stub(%{})
      Application.put_env(:lightpath, :jwt_secret, "")
      assert {:error, msg} = WorkerClient.news("v")
      assert msg =~ "LIGHTPATH_JWT_SECRET"
      refute_receive %{method: _}, 100
    end
  end

  describe "explain/2" do
    test "posts the fixture and returns model, text and neurons" do
      start_stub(%{
        "POST /api/explain" => {200, ~s({"model":"m8","text":"ZFS is not loaded.","neurons":4.5})}
      })

      assert {:ok, %{model: "m8", text: "ZFS is not loaded.", neurons: 4.5}} =
               WorkerClient.explain(@fixture, "visitor-1")

      assert_receive %{
        method: "POST",
        path: "/api/explain",
        body: raw,
        content_type: [ctype],
        authorization: auth
      }

      assert ctype =~ "application/json"

      assert JSON.decode!(raw) == %{
               "id" => "zpool-status",
               "argv" => ["zpool", "status"],
               "exit_code" => 1,
               "stdout" => "",
               "stderr" => "The ZFS modules cannot be auto-loaded.",
               "error" => ""
             }

      c = claims(auth)
      assert c["sub"] == "visitor-1"
      assert c["aud"] == "lightpath-worker"
      assert abs(c["iat"] - System.system_time(:second)) <= 2
      assert (c["exp"] - c["iat"]) in 1..300
    end

    test "a reply without neurons still works (0)" do
      start_stub(%{"POST /api/explain" => {200, ~s({"model":"m","text":"t"})}})
      assert {:ok, %{neurons: 0}} = WorkerClient.explain(@fixture, "v")
    end

    test "a trailing slash in the URL does not double up" do
      url = start_stub(%{"POST /api/explain" => {200, ~s({"model":"m","text":"t"})}})
      Application.put_env(:lightpath, :worker_url, url <> "/")
      assert {:ok, _} = WorkerClient.explain(@fixture, "v")
      assert_receive %{path: "/api/explain"}
    end
  end

  describe "errors" do
    test "the Worker's error message comes through" do
      start_stub(%{
        "POST /api/explain" => {502, ~s({"error":"Workers AI failed: quota exceeded"})}
      })

      assert {:error, msg} = WorkerClient.explain(@fixture, "v")
      assert msg =~ "quota exceeded"
    end

    test "a non-2xx reply without an error field reports the status" do
      start_stub(%{"GET /api/usage" => {500, "oops"}})
      assert {:error, msg} = WorkerClient.usage("v")
      assert msg =~ "500"
    end

    test "a 2xx reply that is not the expected JSON is an error" do
      start_stub(%{
        "POST /api/explain" => {200, ~s({"unexpected":true})},
        "GET /api/usage" => {200, "[]"}
      })

      assert {:error, _} = WorkerClient.explain(@fixture, "v")
      assert {:error, _} = WorkerClient.usage("v")
    end

    test "a connection failure is an error, not a crash" do
      Application.put_env(:lightpath, :worker_url, "http://127.0.0.1:1")
      assert {:error, msg} = WorkerClient.usage("v")
      assert is_binary(msg)
    end
  end

  test "usage/1" do
    start_stub(%{
      "GET /api/usage" =>
        {200, ~s({"day":"2026-11-08","neurons":59.3,"calls":2,"allowance":10000,"rough":true})}
    })

    assert {:ok, %{"neurons" => 59.3, "calls" => 2, "allowance" => 10000}} =
             WorkerClient.usage("v")

    assert_receive %{method: "GET", path: "/api/usage"}
  end

  describe "triage" do
    test "triage/4 starts an instance" do
      start_stub(%{"POST /api/triage" => {202, ~s({"id":"t-1"})}})
      assert {:ok, "t-1"} = WorkerClient.triage("v", "chat-1", "Is ZFS up?", true)
      assert_receive %{method: "POST", path: "/api/triage", body: raw}

      assert JSON.decode!(raw) == %{
               "session" => "chat-1",
               "message" => "Is ZFS up?",
               "hard" => true
             }
    end

    test "triage_status/2 returns status, output and error" do
      start_stub(%{
        "GET /api/triage/status" =>
          {200, ~s({"status":"complete","output":{"text":"done","model":"m"}})}
      })

      assert {:ok, %{status: "complete", output: %{"text" => "done"}, error: nil}} =
               WorkerClient.triage_status("v", "t-1")

      assert_receive %{path: "/api/triage/status", query: %{"id" => "t-1"}}
    end

    test "triage_status/2 with an errored instance" do
      start_stub(%{"GET /api/triage/status" => {200, ~s({"status":"errored","error":"4006"})}})

      assert {:ok, %{status: "errored", output: nil, error: "4006"}} =
               WorkerClient.triage_status("v", "x")
    end

    test "an unknown instance is an error" do
      start_stub(%{"GET /api/triage/status" => {404, ~s({"error":"no such instance"})}})
      assert {:error, "no such instance"} = WorkerClient.triage_status("v", "x")
    end
  end

  test "history/2" do
    start_stub(%{
      "GET /api/chat/history" =>
        {200, ~s({"messages":[{"role":"user","content":"q","model":"","at":1}]})}
    })

    assert {:ok, [%{"role" => "user", "content" => "q"}]} = WorkerClient.history("v", "chat-1")
    assert_receive %{path: "/api/chat/history", query: %{"session" => "chat-1"}}
  end

  describe "news" do
    test "upload_packages/2 PUTs the list" do
      start_stub(%{"PUT /api/news/packages" => {200, ~s({"count":2})}})
      assert {:ok, 2} = WorkerClient.upload_packages("v", ["linux", "zfs-dkms"])
      assert_receive %{method: "PUT", path: "/api/news/packages", body: raw}
      assert JSON.decode!(raw) == %{"packages" => ["linux", "zfs-dkms"]}
    end

    test "news/1 and news_status/2" do
      start_stub(%{
        "POST /api/news" => {202, ~s({"id":"n-1"})},
        "GET /api/news/status" => {200, ~s({"status":"running"})}
      })

      assert {:ok, "n-1"} = WorkerClient.news("v")

      assert {:ok, %{status: "running", output: nil, error: nil}} =
               WorkerClient.news_status("v", "n-1")

      assert_receive %{path: "/api/news/status", query: %{"id" => "n-1"}}
    end

    test "news_latest/1: a digest, or nil when there is none" do
      start_stub(%{"GET /api/news/latest" => {200, ~s({"key":"k","text":"t","items":[]})}})
      assert {:ok, %{"text" => "t"}} = WorkerClient.news_latest("v")

      start_stub(%{})
      assert {:ok, nil} = WorkerClient.news_latest("v")
    end
  end
end
