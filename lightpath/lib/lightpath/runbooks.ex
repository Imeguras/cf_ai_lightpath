defmodule Lightpath.Runbooks do
  @moduledoc """
  Runbooks: what to do about one ranked cause. Plain text files at
  `priv/runbooks/<rule id>/<cause id>.md`, written and reviewed by a person
  (the AI never writes them), shown as text under the cause.
  """

  @doc """
  The runbook for `cause_id` of rule `rule_id` under `dir` (default: the
  app's `priv/runbooks`), trimmed. `:none` when there is no file, the file
  is empty, or either id is not lowercase letters, digits and dashes (so an
  id can never reach outside `dir`).
  """
  @spec get(String.t(), String.t(), Path.t() | nil) :: {:ok, String.t()} | :none
  def get(rule_id, cause_id, dir \\ nil) do
    dir = dir || Application.app_dir(:lightpath, "priv/runbooks")

    with true <- safe?(rule_id) and safe?(cause_id),
         {:ok, text} <- File.read(Path.join([dir, rule_id, cause_id <> ".md"])),
         text when text != "" <- String.trim(text) do
      {:ok, text}
    else
      _ -> :none
    end
  end

  defp safe?(id), do: is_binary(id) and Regex.match?(~r/^[a-z0-9-]+$/, id)
end
