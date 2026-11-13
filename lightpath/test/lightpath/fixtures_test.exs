defmodule Lightpath.FixturesTest do
  use ExUnit.Case, async: true

  alias Lightpath.Fixtures
  alias Lightpath.Fixtures.{Fixture, Set}

  @moduletag :tmp_dir

  defp write_set(root, name, created_at, results) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    entries =
      for r <- results do
        File.write!(Path.join(dir, r["id"] <> ".json"), JSON.encode!(r))
        %{"id" => r["id"], "file" => r["id"] <> ".json", "exit_code" => r["exit_code"]}
      end

    manifest = %{
      "target" => "labuser@192.0.2.1",
      "created_at" => created_at,
      "entries" => entries
    }

    File.write!(Path.join(dir, "index.json"), JSON.encode!(manifest))
    dir
  end

  defp result(id, exit_code, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "argv" => [id],
        "exit_code" => exit_code,
        "stdout" => "out of #{id}",
        "stderr" => ""
      },
      extra
    )
  end

  describe "load/1" do
    test "reads the manifest header and fixtures in manifest order", %{tmp_dir: tmp} do
      dir =
        write_set(tmp, "zfs-down", "2026-11-04T17:32:40Z", [
          result("uname", 0),
          result("zpool-status", 1, %{"stderr" => "The ZFS modules cannot be auto-loaded."}),
          result("ib-sysfs", 0)
        ])

      assert {:ok, %Set{} = set} = Fixtures.load(dir)
      assert set.name == "zfs-down"
      assert set.target == "labuser@192.0.2.1"
      assert set.created_at == "2026-11-04T17:32:40Z"
      assert Enum.map(set.fixtures, & &1.id) == ["uname", "zpool-status", "ib-sysfs"]

      zpool = Enum.at(set.fixtures, 1)
      assert %Fixture{exit_code: 1, argv: ["zpool-status"]} = zpool
      assert zpool.stderr =~ "cannot be auto-loaded"
    end

    test "missing optional fields read as empty values", %{tmp_dir: tmp} do
      dir =
        write_set(tmp, "s", "2026-11-04T00:00:00Z", [
          %{"id" => "bare", "argv" => ["bare"], "exit_code" => 0}
        ])

      assert {:ok, %Set{fixtures: [f]}} = Fixtures.load(dir)
      assert f.stdout == ""
      assert f.stderr == ""
      assert f.error == ""
      assert f.timed_out == false
      assert f.truncated == false
      assert f.duration_ms == 0
    end

    test "no index.json", %{tmp_dir: tmp} do
      assert Fixtures.load(tmp) == {:error, :no_manifest}
    end

    test "index.json is not JSON", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "index.json"), "{not json")
      assert Fixtures.load(tmp) == {:error, :bad_manifest}
    end

    test "a listed fixture file is missing", %{tmp_dir: tmp} do
      dir = write_set(tmp, "s", "2026-11-04T00:00:00Z", [result("uname", 0)])
      File.rm!(Path.join(dir, "uname.json"))
      assert Fixtures.load(dir) == {:error, {:bad_fixture, "uname"}}
    end
  end

  describe "get/2" do
    test "finds a fixture by id, or reports not found", %{tmp_dir: tmp} do
      dir =
        write_set(tmp, "s", "2026-11-04T00:00:00Z", [result("uname", 0), result("dkms-status", 0)])

      {:ok, set} = Fixtures.load(dir)
      assert {:ok, %Fixture{id: "dkms-status"}} = Fixtures.get(set, "dkms-status")
      assert Fixtures.get(set, "nope") == {:error, :not_found}
      assert Fixtures.get(set, "../uname") == {:error, :not_found}
    end
  end

  describe "latest/1" do
    test "picks the set with the newest created_at, not the newest name", %{tmp_dir: tmp} do
      write_set(tmp, "zzz-old", "2026-10-01T00:00:00Z", [result("uname", 0)])
      write_set(tmp, "aaa-new", "2026-11-04T17:32:40Z", [result("uname", 0)])
      File.mkdir_p!(Path.join(tmp, "not-a-set"))
      assert {:ok, %Set{name: "aaa-new"}} = Fixtures.latest(tmp)
    end

    test "no sets under root", %{tmp_dir: tmp} do
      assert Fixtures.latest(tmp) == {:error, :no_sets}
      assert Fixtures.latest(Path.join(tmp, "missing")) == {:error, :no_sets}
    end
  end

  describe "status/1" do
    test "classifies exit codes, timeouts and failures to run" do
      assert Fixtures.status(%Fixture{exit_code: 0, error: "", timed_out: false}) == :ok
      assert Fixtures.status(%Fixture{exit_code: 3, error: "", timed_out: false}) == :failed

      assert Fixtures.status(%Fixture{
               exit_code: -1,
               error: "timed out after 30s",
               timed_out: true
             }) == :not_run

      assert Fixtures.status(%Fixture{exit_code: -1, error: "ssh failed", timed_out: false}) ==
               :not_run
    end
  end

  describe "list/1" do
    test "every set, newest first", %{tmp_dir: tmp} do
      write_set(tmp, "old", "2026-11-04T00:00:00Z", [result("a", 0)])
      write_set(tmp, "new", "2026-11-08T00:00:00Z", [result("a", 0)])
      write_set(tmp, "mid", "2026-11-06T00:00:00Z", [result("a", 0)])
      File.mkdir_p!(Path.join(tmp, "not-a-set"))
      File.write!(Path.join(tmp, "stray.txt"), "x")

      assert Enum.map(Fixtures.list(tmp), & &1.name) == ["new", "mid", "old"]
    end

    test "nothing there", %{tmp_dir: tmp} do
      assert Fixtures.list(tmp) == []
      assert Fixtures.list(Path.join(tmp, "missing")) == []
    end
  end

  describe "kind/1" do
    defp f(exit_code, fields \\ []) do
      struct(
        %Fixture{
          argv: ["cmd"],
          exit_code: exit_code,
          stdout: "",
          stderr: "",
          error: "",
          timed_out: false
        },
        fields
      )
    end

    test "ok and not run follow status/1" do
      assert Fixtures.kind(f(0)) == :ok
      assert Fixtures.kind(f(0, stderr: "netlink error: Operation not permitted")) == :ok
      assert Fixtures.kind(f(-1, timed_out: true)) == :not_run
      assert Fixtures.kind(f(-1, error: "exec: not found")) == :not_run
    end

    test "missing permission" do
      for stderr <- [
            "dmesg: read kernel buffer failed: Operation not permitted",
            "open /dev/x: Permission denied",
            "you must be root to do this",
            "ERROR: are you root?"
          ] do
        assert Fixtures.kind(f(1, stderr: stderr)) == :needs_privilege, stderr
      end
    end

    test "a missing package or command is a real failure (it happens after updates)" do
      for stderr <- [
            "error: package 'linux-lts' was not found",
            "bash: zpool: command not found",
            "zfs is not installed"
          ] do
        assert Fixtures.kind(f(1, stderr: stderr)) == :failed, stderr
      end
    end

    test "permission wins over other failures" do
      assert Fixtures.kind(f(1, stderr: "Permission denied; package was not found")) ==
               :needs_privilege

      assert Fixtures.kind(f(3, argv: ["systemctl", "status"], stderr: "Permission denied")) ==
               :needs_privilege
    end

    test "systemctl exit 3 is an inactive unit; other exits are failures" do
      assert Fixtures.kind(f(3, argv: ["systemctl", "status", "kubelet.service"])) == :inactive
      assert Fixtures.kind(f(1, argv: ["systemctl", "status", "x"])) == :failed
      assert Fixtures.kind(f(3, argv: ["zpool", "status"])) == :failed
    end

    test "pacman/paru -Qu exiting 1 with no output means nothing to upgrade" do
      for argv <- [["paru", "-Qua"], ["pacman", "-Qu"], ["paru", "-Qu"]] do
        assert Fixtures.kind(f(1, argv: argv)) == :ok, inspect(argv)
      end

      assert Fixtures.kind(f(1, argv: ["paru", "-Qua"], stderr: "error: failed to fetch")) ==
               :failed

      assert Fixtures.kind(f(1, argv: ["paru", "-Qua"], stdout: "zfs-dkms 2.4.4 -> 2.4.5")) ==
               :failed

      assert Fixtures.kind(f(1, argv: ["paru", "-Q"])) == :failed
    end

    test "anything else non-zero is a failure, including a missing device" do
      assert Fixtures.kind(
               f(1, stderr: "Could not open device at /dev/ipmi0: No such file or directory")
             ) ==
               :failed

      assert Fixtures.kind(f(2)) == :failed
    end
  end
end
