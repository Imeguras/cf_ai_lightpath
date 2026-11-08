defmodule Lightpath.Worker do
  @moduledoc """
  What the web app asks of the Lightpath Worker (`worker/`). The real
  implementation is `Lightpath.WorkerClient`; tests swap in a fake through
  the `:lightpath, :worker` setting.

  `visitor` is a per-browser id: it becomes the JWT subject, which the
  Worker rate-limits by. Errors are readable strings, shown to the user.
  """

  alias Lightpath.Fixtures.Fixture

  @type visitor :: String.t()
  @type answer :: %{model: String.t(), text: String.t(), neurons: number()}
  @typedoc "A Workflow instance: status, its output (decoded JSON) when complete, its error when failed."
  @type instance :: %{status: String.t(), output: map() | nil, error: String.t() | nil}

  @doc "Whether the Worker can be used at all (URL and secret configured)."
  @callback available?() :: boolean()

  @doc "Explains one fixture."
  @callback explain(Fixture.t(), visitor()) :: {:ok, answer()} | {:error, String.t()}

  @doc "Today's rough neuron estimate: `%{neurons, calls, allowance}`."
  @callback usage(visitor()) :: {:ok, map()} | {:error, String.t()}

  @doc "Starts a triage Workflow for `message` in chat `session`; returns the instance id."
  @callback triage(visitor(), session :: String.t(), message :: String.t(), hard :: boolean()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "A triage instance's status."
  @callback triage_status(visitor(), id :: String.t()) :: {:ok, instance()} | {:error, String.t()}

  @doc "A chat session's stored messages, oldest first (maps with string keys)."
  @callback history(visitor(), session :: String.t()) :: {:ok, [map()]} | {:error, String.t()}

  @doc "Replaces the installed package list the news digest matches against."
  @callback upload_packages(visitor(), [String.t()]) ::
              {:ok, non_neg_integer()} | {:error, String.t()}

  @doc "Starts a news digest Workflow; returns the instance id."
  @callback news(visitor()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "A news instance's status."
  @callback news_status(visitor(), id :: String.t()) :: {:ok, instance()} | {:error, String.t()}

  @doc "The latest news digest (decoded JSON), or nil when there is none yet."
  @callback news_latest(visitor()) :: {:ok, map() | nil} | {:error, String.t()}

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:lightpath, :worker, Lightpath.WorkerClient)
end
