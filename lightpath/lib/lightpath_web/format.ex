defmodule LightpathWeb.Format do
  @moduledoc "How times and event changes are shown. Times are ISO 8601 strings."

  @doc ~s(A recorded time for headings: "8 Nov 2026, 20:38 UTC". Unparsable text is returned as is; nil as "".)
  def when_utc(iso), do: with_time(iso, &Calendar.strftime(&1, "%-d %b %Y, %H:%M UTC"))

  @doc ~s(The UTC time of day: "20:01".)
  def clock(iso), do: with_time(iso, &Calendar.strftime(&1, "%H:%M"))

  @doc ~s(The UTC day, for grouping: "Sun 8 Nov".)
  def day(iso), do: with_time(iso, &Calendar.strftime(&1, "%a %-d %b"))

  @doc """
  The badge colour for an event change: "bad" (failed, error, link-down),
  "warn" (warning, restarting), "good" (started, installed, upgraded,
  link-up) or "neutral" (anything else).
  """
  def badge(change) when change in ["failed", "error", "link-down"], do: "bad"
  def badge(change) when change in ["warning", "restarting"], do: "warn"
  def badge(change) when change in ["started", "installed", "upgraded", "link-up"], do: "good"
  def badge(_), do: "neutral"

  defp with_time(nil, _), do: ""

  defp with_time(iso, format) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> format.(DateTime.shift_zone!(dt, "Etc/UTC"))
      {:error, _} -> iso
    end
  end
end
