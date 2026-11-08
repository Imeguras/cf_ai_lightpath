defmodule Lightpath.WorkerClient do
  @moduledoc """
  Calls the Lightpath Worker (`worker/`) over HTTP, using Erlang's built-in
  `:httpc`, so there is no HTTP client dependency.

  The Worker's base URL comes from the `:lightpath, :worker_url` setting
  (`LIGHTPATH_WORKER_URL` in releases), and every request carries a fresh
  JWT signed with `:lightpath, :jwt_secret` (`LIGHTPATH_JWT_SECRET`, shared
  with the Worker) whose subject is the visitor. When either is not set,
  `available?/0` is false and every call returns an error without making a
  request.

  Errors are readable strings: the Worker's own `"error"` message for a
  non-2xx reply that has one, otherwise the HTTP status; a connection failure
  or timeout; a reply that is not the expected JSON; or missing settings.
  Requests time out after 60 seconds.
  """
  @behaviour Lightpath.Worker

  alias Lightpath.Fixtures.Fixture

  @timeout 60_000

  @impl true
  def available?, do: url() != nil and secret() != nil

  @impl true
  def explain(%Fixture{} = f, visitor) do
    body = %{
      id: f.id,
      argv: f.argv,
      exit_code: f.exit_code,
      stdout: f.stdout,
      stderr: f.stderr,
      error: f.error
    }

    with {:ok, %{"model" => model, "text" => text} = reply}
         when is_binary(model) and is_binary(text) <- call(:post, "/api/explain", body, visitor) do
      {:ok, %{model: model, text: text, neurons: reply["neurons"] || 0}}
    else
      {:ok, _} -> unexpected()
      {:error, {_, message}} -> {:error, message}
    end
  end

  @impl true
  def usage(visitor) do
    case call(:get, "/api/usage", nil, visitor) do
      {:ok, %{"neurons" => n} = reply} when is_number(n) -> {:ok, reply}
      {:ok, _} -> unexpected()
      {:error, {_, message}} -> {:error, message}
    end
  end

  @impl true
  def triage(visitor, session, message, hard) do
    body = %{session: session, message: message, hard: hard}
    started(call(:post, "/api/triage", body, visitor))
  end

  @impl true
  def triage_status(visitor, id),
    do: status(call(:get, "/api/triage/status?" <> q(id: id), nil, visitor))

  @impl true
  def history(visitor, session) do
    case call(:get, "/api/chat/history?" <> q(session: session), nil, visitor) do
      {:ok, %{"messages" => messages}} when is_list(messages) -> {:ok, messages}
      {:ok, _} -> unexpected()
      {:error, {_, message}} -> {:error, message}
    end
  end

  @impl true
  def upload_packages(visitor, packages) do
    case call(:put, "/api/news/packages", %{packages: packages}, visitor) do
      {:ok, %{"count" => n}} when is_integer(n) -> {:ok, n}
      {:ok, _} -> unexpected()
      {:error, {_, message}} -> {:error, message}
    end
  end

  @impl true
  def news(visitor), do: started(call(:post, "/api/news", nil, visitor))

  @impl true
  def news_status(visitor, id),
    do: status(call(:get, "/api/news/status?" <> q(id: id), nil, visitor))

  @impl true
  def news_latest(visitor) do
    case call(:get, "/api/news/latest", nil, visitor) do
      {:ok, %{} = digest} -> {:ok, digest}
      {:ok, _} -> unexpected()
      {:error, {404, _}} -> {:ok, nil}
      {:error, {_, message}} -> {:error, message}
    end
  end

  defp started({:ok, %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp started({:ok, _}), do: unexpected()
  defp started({:error, {_, message}}), do: {:error, message}

  defp status({:ok, %{"status" => s} = reply}) when is_binary(s) do
    {:ok, %{status: s, output: reply["output"], error: reply["error"]}}
  end

  defp status({:ok, _}), do: unexpected()
  defp status({:error, {_, message}}), do: {:error, message}

  defp unexpected, do: {:error, "the Worker sent an unexpected reply"}

  defp q(params), do: URI.encode_query(params)

  # {:ok, decoded JSON} for a 2xx reply, else {:error, {http status or nil,
  # message}}. Public functions turn the latter into {:error, message}.
  defp call(method, path, body, visitor) do
    cond do
      url() == nil ->
        {:error, {nil, "the Worker URL is not configured (LIGHTPATH_WORKER_URL)"}}

      secret() == nil ->
        {:error, {nil, "the JWT secret is not configured (LIGHTPATH_JWT_SECRET)"}}

      true ->
        request(method, url() <> path, body, visitor)
    end
  end

  defp request(method, url, body, visitor) do
    token = Lightpath.Jwt.for_worker(secret(), visitor)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    request =
      case body do
        nil when method in [:get, :delete] ->
          {String.to_charlist(url), headers}

        nil ->
          {String.to_charlist(url), headers, ~c"application/json", "{}"}

        body ->
          {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)}
      end

    http_opts = [timeout: @timeout, connect_timeout: 10_000, ssl: tls_options()]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, reply}} -> decode(status, reply)
      {:error, reason} -> {:error, {nil, "could not reach the Worker: #{inspect(reason)}"}}
    end
  end

  defp decode(status, reply) when status in 200..299 do
    case JSON.decode(reply) do
      {:ok, data} -> {:ok, data}
      _ -> {:error, {status, "the Worker sent an unexpected reply"}}
    end
  end

  defp decode(status, reply) do
    message =
      case JSON.decode(reply) do
        {:ok, %{"error" => message}} when is_binary(message) -> message
        _ -> "the Worker answered HTTP #{status}"
      end

    {:error, {status, message}}
  end

  defp url do
    case Application.get_env(:lightpath, :worker_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp secret do
    case Application.get_env(:lightpath, :jwt_secret) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  # Verify certificates against the system CA store (needed for workers.dev).
  defp tls_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
