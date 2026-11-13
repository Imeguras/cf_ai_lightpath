defmodule Lightpath.FakeProbe do
  @moduledoc """
  A stand-in for the probe daemon in LiveView tests. Configure with
  `Application.put_env(:lightpath, :fake_probe, %{...})`: `:test` (a pid
  that gets `{:probe, name, args}`), `:available?`, and any callback name
  with a reply or a function of its arguments.
  """
  @behaviour Lightpath.Probe

  @impl true
  def available?, do: Map.get(cfg(), :available?, true)

  @impl true
  def probe, do: reply(:probe, [], {:ok, "live-test"})

  @impl true
  def status,
    do: reply(:status, [], {:ok, %{"running" => false, "last_set" => "", "pending" => []}})

  @impl true
  def events(since) do
    default = [
      %{
        "time" => "2026-11-08T19:53:37Z",
        "kind" => "package",
        "subject" => "linux",
        "change" => "upgraded",
        "message" => "linux"
      },
      %{
        "time" => "2026-11-08T20:01:00Z",
        "kind" => "unit",
        "subject" => "kubelet.service",
        "change" => "failed",
        "message" => "kubelet.service: Failed with result 'exit-code'.",
        "repeats" => 190
      }
    ]

    reply(:events, [since], {:ok, default})
  end

  defp cfg, do: Application.get_env(:lightpath, :fake_probe, %{})

  defp reply(name, args, default) do
    c = cfg()
    if pid = c[:test], do: send(pid, {:probe, name, args})

    case Map.fetch(c, name) do
      {:ok, f} when is_function(f) -> apply(f, args)
      {:ok, value} -> value
      :error -> default
    end
  end
end
