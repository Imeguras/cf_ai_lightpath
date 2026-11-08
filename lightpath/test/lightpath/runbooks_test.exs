defmodule Lightpath.RunbooksTest do
  use ExUnit.Case, async: true

  alias Lightpath.Runbooks

  @moduletag :tmp_dir

  test "reads <rule>/<cause>.md, trimmed", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "zfs-pools-unavailable"))

    File.write!(
      Path.join(tmp, "zfs-pools-unavailable/kernel-unsupported.md"),
      "\n  Step 1\nStep 2\n\n"
    )

    assert Runbooks.get("zfs-pools-unavailable", "kernel-unsupported", tmp) ==
             {:ok, "Step 1\nStep 2"}
  end

  test "missing or empty is :none", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "r"))
    File.write!(Path.join(tmp, "r/empty.md"), "  \n")
    assert Runbooks.get("r", "missing", tmp) == :none
    assert Runbooks.get("r", "empty", tmp) == :none
    assert Runbooks.get("nope", "x", tmp) == :none
  end

  test "ids that could escape the directory are refused", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "secret.md"), "do not show")
    File.mkdir_p!(Path.join(tmp, "r"))

    for {rule, cause} <- [
          {"r", "../secret"},
          {"..", "secret"},
          {"r", "Secret"},
          {"r/../", "secret"},
          {"r", ""}
        ] do
      assert Runbooks.get(rule, cause, tmp) == :none, "#{rule} / #{cause}"
    end
  end

  test "the shipped runbooks belong to shipped rules and causes" do
    rules_dir = Application.app_dir(:lightpath, "priv/rules")
    {:ok, rules} = Lightpath.Diagnosis.load_all(rules_dir)
    known = for r <- rules, c <- r.causes, into: MapSet.new(), do: {r.id, c.id}

    files = Path.wildcard(Application.app_dir(:lightpath, "priv/runbooks/*/*.md"))
    assert files != []

    for f <- files do
      pair = {f |> Path.dirname() |> Path.basename(), Path.basename(f, ".md")}
      assert pair in known, "#{f} matches no rule cause"
      assert {:ok, _} = Runbooks.get(elem(pair, 0), elem(pair, 1))
    end
  end
end
