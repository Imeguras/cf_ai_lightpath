defmodule Lightpath.ProbeClient do
  @moduledoc """
  Talks to the probe daemon's control API over its unix socket
  (`:lightpath, :probe_socket`, `LIGHTPATH_PROBE_SOCKET` in releases) with
  Erlang's `:httpc`, so there is no dependency. Without a configured socket,
  or when the file does not exist, `available?/0` is false and every call
  returns an error without connecting.

  `probe/0` waits up to 10 minutes (a full run takes a while); the other
  calls 10 seconds. Errors carry the daemon's own `"error"` message when it
  sends one (for example "a probe run is already in progress").
  """
  @behaviour Lightpath.Probe

  @profile :lightpath_probe

  @impl true
  def available?, do: socket() != nil

  @impl true
  def probe do
    case request(:post, "/probe", 600_000) do
      {:ok, %{"set" => name}} when is_binary(name) -> {:ok, name}
      {:ok, _} -> unexpected()
      error -> error
    end
  end

  @impl true
  def status do
    case request(:get, "/status", 10_000) do
      {:ok, %{"running" => _} = status} -> {:ok, status}
      {:ok, _} -> unexpected()
      error -> error
    end
  end

  @impl true
  def events(%DateTime{} = since) do
    query = URI.encode_query(since: DateTime.to_iso8601(DateTime.truncate(since, :second)))

    case request(:get, "/events?" <> query, 10_000) do
      {:ok, %{"events" => events}} when is_list(events) -> {:ok, events}
      {:ok, _} -> unexpected()
      error -> error
    end
  end

  defp unexpected, do: {:error, "the probe daemon sent an unexpected reply"}

  defp socket do
    case Application.get_env(:lightpath, :probe_socket) do
      path when is_binary(path) and path != "" -> if File.exists?(path), do: path
      _ -> nil
    end
  end

  defp request(method, path, timeout) do
    case socket() do
      nil ->
        {:error, "the probe daemon's socket is not available (LIGHTPATH_PROBE_SOCKET)"}

      sock ->
        ensure_profile(sock)
        url = String.to_charlist("http://localhost" <> path)
        req = if method == :post, do: {url, [], ~c"application/json", "{}"}, else: {url, []}
        opts = [timeout: timeout, connect_timeout: 5_000]

        case :httpc.request(method, req, opts, [body_format: :binary], @profile) do
          {:ok, {{_, status, _}, _headers, body}} -> decode(status, body)
          {:error, reason} -> {:error, "could not reach the probe daemon: #{inspect(reason)}"}
        end
    end
  end

  # A separate :httpc profile that connects over the unix socket. No
  # keep-alive: a reused connection would outlive a daemon restart (or a
  # socket change) and fail; a local connect costs nothing.
  defp ensure_profile(sock) do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok =
      :httpc.set_options(
        [
          ipfamily: :local,
          unix_socket: String.to_charlist(sock),
          keep_alive_timeout: 0,
          max_keep_alive_length: 0
        ],
        @profile
      )
  end

  defp decode(status, body) when status in 200..299 do
    case JSON.decode(body) do
      {:ok, data} -> {:ok, data}
      _ -> unexpected()
    end
  end

  defp decode(status, body) do
    case JSON.decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> {:error, message}
      _ -> {:error, "the probe daemon answered HTTP #{status}"}
    end
  end
end
