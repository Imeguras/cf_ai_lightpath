defmodule LightpathWeb.Live.Helpers do
  @moduledoc """
  What every page shares: the visitor id, whether the Worker can be used,
  today's usage, and polling of Workflow instances.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [assign_async: 3]

  alias Lightpath.Worker

  @doc """
  Assigns `:visitor` (from the session; see `LightpathWeb.Visitor`),
  `:worker` (the configured implementation), `:can_ai` (whether it is
  available) and `:usage` (loaded asynchronously when it is).
  """
  def assign_common(socket, session) do
    visitor = session["visitor"] || "anonymous"
    worker = Worker.impl()
    can_ai = worker.available?()
    socket = assign(socket, visitor: visitor, worker: worker, can_ai: can_ai)

    if can_ai do
      assign_async(socket, :usage, fn ->
        case worker.usage(visitor) do
          {:ok, usage} -> {:ok, %{usage: usage}}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      assign(socket, usage: nil)
    end
  end

  @doc "Milliseconds between status checks of a Workflow instance (`:lightpath, :poll_ms`)."
  def poll_ms, do: Application.get_env(:lightpath, :poll_ms, 1500)

  @doc "Status checks before giving up on an instance (about two minutes at the default)."
  def max_polls, do: 80

  @doc "True when a Workflow status is final."
  def finished?(status), do: status in ["complete", "errored", "terminated"]
end
