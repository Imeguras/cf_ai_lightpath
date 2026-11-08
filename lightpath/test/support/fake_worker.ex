defmodule Lightpath.FakeWorker do
  @moduledoc """
  A stand-in for the Worker in LiveView tests. Configure with
  `Application.put_env(:lightpath, :fake_worker, %{...})`:

    * `:test` - a pid that gets `{:worker, name, args}` for every call
    * `:available?` - false to make the Worker unavailable
    * any callback name (`:explain`, `:triage_status`, ...) - the reply to
      return, or a function of the call's arguments
  """
  @behaviour Lightpath.Worker

  @digest %{
    "key" => "k1",
    "created" => 1_794_000_000_000,
    "model" => "@cf/fake/large",
    "text" => "Fake digest: update php.",
    "neurons" => 30.5,
    "cached" => false,
    "items" => [
      %{
        "title" => "Update to php 8.5.12",
        "link" => "https://archlinux.org/news/php/",
        "published" => 1_792_591_122_000,
        "matches" => ["php"]
      }
    ]
  }

  def digest, do: @digest

  @impl true
  def available?, do: Map.get(cfg(), :available?, true)

  @impl true
  def explain(f, visitor),
    do:
      reply(
        :explain,
        [f, visitor],
        {:ok, %{model: "@cf/fake/model", text: "Fake explanation for #{f.id}.", neurons: 1.0}}
      )

  @impl true
  def usage(visitor),
    do: reply(:usage, [visitor], {:ok, %{"neurons" => 12.3, "calls" => 2, "allowance" => 10_000}})

  @impl true
  def triage(visitor, session, message, hard),
    do: reply(:triage, [visitor, session, message, hard], {:ok, "t-1"})

  @impl true
  def triage_status(visitor, id) do
    output = %{
      "model" => "@cf/fake/large",
      "text" => "Fake triage answer.",
      "escalated" => true,
      "reason" => "the small model suggested a command",
      "neurons" => 3.5
    }

    reply(:triage_status, [visitor, id], {:ok, %{status: "complete", output: output, error: nil}})
  end

  @impl true
  def history(visitor, session), do: reply(:history, [visitor, session], {:ok, []})

  @impl true
  def upload_packages(visitor, packages),
    do: reply(:upload_packages, [visitor, packages], {:ok, length(packages)})

  @impl true
  def news(visitor), do: reply(:news, [visitor], {:ok, "n-1"})

  @impl true
  def news_status(visitor, id),
    do:
      reply(
        :news_status,
        [visitor, id],
        {:ok, %{status: "complete", output: @digest, error: nil}}
      )

  @impl true
  def news_latest(visitor), do: reply(:news_latest, [visitor], {:ok, nil})

  defp cfg, do: Application.get_env(:lightpath, :fake_worker, %{})

  defp reply(name, args, default) do
    c = cfg()
    if pid = c[:test], do: send(pid, {:worker, name, args})

    case Map.fetch(c, name) do
      {:ok, f} when is_function(f) -> apply(f, args)
      {:ok, value} -> value
      :error -> default
    end
  end
end
