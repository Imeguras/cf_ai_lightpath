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
end
