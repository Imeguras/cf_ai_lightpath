defmodule Lightpath.SuggestTest do
  use ExUnit.Case, async: true

  alias Lightpath.Diagnosis.{Cause, Rule}
  alias Lightpath.Suggest

  @rule %Rule{id: "zfs-pools-unavailable", title: "ZFS pools are unavailable"}
  @evidence %{
    "kernel-above-max" => %{
      "id" => "kernel-above-max",
      "title" => "Running kernel is above zfs-dkms Linux-Maximum"
    },
    "dkms-not-built" => %{
      "id" => "dkms-not-built",
      "title" => "dkms has zfs registered but not built"
    }
  }
  @causes [
    %Cause{
      id: "kernel-unsupported",
      title: "Running kernel is newer than zfs-dkms supports",
      probability: 0.97512,
      contributions: [{"kernel-above-max", 20}, {"dkms-not-built", 3}]
    },
    %Cause{
      id: "dkms-build-failed",
      title: "dkms build failed for another reason",
      probability: 0.0201,
      contributions: [{"dkms-not-built", 3}]
    },
    %Cause{id: "other", title: "Something else", probability: 0.0048, contributions: []}
  ]

  test "carries the problem, every cause with its percentage and evidence, in order" do
    m = Suggest.message(@rule, @causes, @evidence, nil)
    assert m =~ "ZFS pools are unavailable"
    assert m =~ "97.5%"
    assert m =~ "2.0%"
    assert m =~ "0.5%"
    assert m =~ "Running kernel is above zfs-dkms Linux-Maximum"
    assert m =~ "dkms has zfs registered but not built"

    {a, _} = :binary.match(m, "Running kernel is newer")
    {b, _} = :binary.match(m, "dkms build failed")
    {c, _} = :binary.match(m, "Something else")
    assert a < b and b < c
  end

  test "says the ranking is fixed, asks for a short next step and what would change it" do
    m = Suggest.message(@rule, @causes, @evidence, nil)
    assert m =~ ~r/rules/i
    assert m =~ ~r/not.*(replace|override|change)|do not re-?rank/i
    assert m =~ "120 words"
    assert m =~ ~r/evidence would change/i
    refute m =~ ~r/runbook/i
  end

  test "includes the runbook, marked as written by a person" do
    m = Suggest.message(@rule, @causes, @evidence, "paru -S zfs-dkms\nmodprobe zfs")
    assert m =~ "paru -S zfs-dkms\nmodprobe zfs"
    assert m =~ ~r/runbook/i
    assert m =~ ~r/(written by|from) (a person|the operator)/i
  end
end
