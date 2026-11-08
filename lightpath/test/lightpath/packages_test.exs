defmodule Lightpath.PackagesTest do
  use ExUnit.Case, async: true

  alias Lightpath.Fixtures.{Fixture, Set}
  alias Lightpath.Packages

  defp set(fixtures), do: %Set{name: "s", target: "t", created_at: "c", fixtures: fixtures}

  defp pq(exit_code, stdout),
    do: %Fixture{
      id: "pacman-q",
      argv: ["pacman", "-Q"],
      exit_code: exit_code,
      stdout: stdout,
      stderr: "",
      error: "",
      timed_out: false
    }

  test "names from pacman -Q, sorted and unique" do
    s = set([pq(0, "zfs-dkms 2.4.4-1\nlinux 7.2.14.arch1-1\n\nlinux 7.2.14.arch1-1\ngtk+ 1.0\n")])
    assert Packages.names(s) == ["gtk+", "linux", "zfs-dkms"]
  end

  test "missing or failed fixture gives none" do
    assert Packages.names(set([])) == []
    assert Packages.names(set([pq(1, "linux 1\n")])) == []
  end

  test "the real evidence lists hundreds of packages" do
    {:ok, s} =
      Lightpath.Fixtures.load(Path.expand("../../../fixtures/public/zfs-up-2026-11-08", __DIR__))

    names = Packages.names(s)
    assert length(names) > 100
    assert "linux" in names and "zfs-dkms" in names
  end
end
