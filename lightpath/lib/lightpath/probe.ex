defmodule Lightpath.Probe do
  @moduledoc """
  What the web app asks of the live probe daemon on the server
  (`probe/cmd/lightpathd`). The real implementation is
  `Lightpath.ProbeClient`; tests swap in a fake through the
  `:lightpath, :probe` setting. Errors are readable strings.
  """

  @doc "Whether the daemon can be reached at all (its socket is configured and exists)."
  @callback available?() :: boolean()

  @doc "Runs every probe now; returns the new evidence set's name."
  @callback probe() :: {:ok, String.t()} | {:error, String.t()}

  @doc "`%{\"running\" => bool, \"last_set\" => name, \"pending\" => [probe ids]}`."
  @callback status() :: {:ok, map()} | {:error, String.t()}

  @doc "The event timeline since `since` (UTC), oldest first: maps with string keys."
  @callback events(since :: DateTime.t()) :: {:ok, [map()]} | {:error, String.t()}

  @doc "The configured implementation."
  def impl, do: Application.get_env(:lightpath, :probe, Lightpath.ProbeClient)
end
