defmodule LightpathWeb.FormatTest do
  use ExUnit.Case, async: true

  alias LightpathWeb.Format

  test "when/1: day, month, year and minute in UTC" do
    assert Format.when_utc("2026-11-08T20:38:11.262Z") == "8 Nov 2026, 20:38 UTC"
    assert Format.when_utc("2026-11-04T17:32:40.454466492Z") == "4 Nov 2026, 17:32 UTC"
    assert Format.when_utc("2026-01-01T00:00:00+02:00") == "31 Dec 2025, 22:00 UTC"
  end

  test "clock/1 and day/1" do
    assert Format.clock("2026-11-08T20:01:00Z") == "20:01"
    assert Format.day("2026-11-08T20:01:00Z") == "Sun 8 Nov"
  end

  test "anything unparsable is shown as it is" do
    for f <- [&Format.when_utc/1, &Format.clock/1, &Format.day/1] do
      assert f.("soon") == "soon"
      assert f.(nil) == ""
    end
  end

  test "badge/1 sorts changes into bad, warn, good and neutral" do
    for c <- ["failed", "error", "link-down"], do: assert(Format.badge(c) == "bad", c)
    for c <- ["warning", "restarting"], do: assert(Format.badge(c) == "warn", c)

    for c <- ["started", "installed", "upgraded", "link-up"],
        do: assert(Format.badge(c) == "good", c)

    for c <- ["stopped", "removed", "whatever", nil],
        do: assert(Format.badge(c) == "neutral", inspect(c))
  end
end
