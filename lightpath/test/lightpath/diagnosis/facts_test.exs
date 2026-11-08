defmodule Lightpath.Diagnosis.FactsTest do
  use ExUnit.Case, async: true

  alias Lightpath.Diagnosis
  alias Lightpath.Diagnosis.Facts
  alias Lightpath.Fixtures
  alias Lightpath.Fixtures.{Fixture, Set}

  defp fx(id, exit_code, stdout, stderr \\ "") do
    %Fixture{
      id: id,
      argv: [id],
      exit_code: exit_code,
      stdout: stdout,
      stderr: stderr,
      error: "",
      timed_out: false
    }
  end

  defp set(fixtures), do: %Set{name: "t", target: "t", created_at: "t", fixtures: fixtures}

  @meta "Meta:          1\nName:          zfs\nVersion:       2.4.0\nLinux-Maximum: 6.18\nLinux-Minimum: 4.18\n"

  defp broken do
    [
      fx("uname", 0, "Linux labhost 7.2.14-arch1-1 #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux\n"),
      fx("zfs-dkms-meta", 0, @meta),
      fx("modinfo-zfs", 1, "", "modinfo: ERROR: Module zfs not found.\n"),
      fx("dkms-status", 0, "zfs/2.4.0: added\n"),
      fx(
        "zpool-status",
        1,
        "",
        "The ZFS modules cannot be auto-loaded.\nTry running 'modprobe zfs' as root.\n"
      ),
      fx(
        "systemctl-zfs",
        3,
        "* zfs-import-cache.service - Import ZFS pools by cache file\n     Loaded: loaded (/usr/lib/systemd/system/zfs-import-cache.service; enabled; preset: enabled)\n"
      ),
      fx(
        "pacman-kernel-zfs",
        1,
        "linux 7.2.14.arch1-1\nlinux-headers 7.2.14.arch1-1\nzfs-dkms 2.4.0-1\n",
        "error: package 'linux-lts' was not found\n"
      ),
      fx(
        "paru-aur-info-zfs",
        0,
        "Repository      : aur\nName            : zfs-dkms\nVersion         : 2.4.4-1\n"
      ),
      fx(
        "virsh-system-pools",
        0,
        " Name      State      Autostart\n default   running    yes\n ISOs      inactive   yes\n"
      )
    ]
  end

  describe "extract/1 on the broken-ZFS shape" do
    setup do: %{facts: Facts.extract(set(broken()))}

    test "versions", %{facts: f} do
      assert f["kernel.running"] == "7.2.14"
      assert f["zfs.dkms_version"] == "2.4.0"
      assert f["zfs.linux_max"] == "6.18"
    end

    test "booleans", %{facts: f} do
      assert f["zfs.kernel_above_max"] == true
      assert f["zfs.module_present"] == false
      assert f["zfs.dkms_built"] == false
      assert f["zfs.pools_unavailable"] == true
      assert f["zfs.import_enabled"] == true
      assert f["zfs.headers_match_kernel"] == true
      assert f["zfs.newer_available"] == true
      assert f["libvirt.pool_inactive"] == true
    end
  end

  describe "extract/1 on a healthy shape" do
    test "flips every boolean" do
      healthy = [
        fx("uname", 0, "Linux h 6.18.3-arch1-1 #1 SMP x86_64 GNU/Linux\n"),
        fx("zfs-dkms-meta", 0, @meta),
        fx("modinfo-zfs", 0, "filename: /lib/modules/6.18.3/updates/dkms/zfs.ko\n"),
        fx("dkms-status", 0, "zfs/2.4.0, 6.18.3-arch1-1, x86_64: installed\n"),
        fx("zpool-status", 0, "  pool: tank\n state: ONLINE\n"),
        fx(
          "systemctl-zfs",
          0,
          "Loaded: loaded (/usr/lib/systemd/system/zfs-import-cache.service; disabled; preset: enabled)\n"
        ),
        fx("pacman-kernel-zfs", 0, "linux 6.18.3.arch1-1\nlinux-headers 6.18.2.arch1-1\n"),
        fx("paru-aur-info-zfs", 0, "Name            : zfs-dkms\nVersion         : 2.4.0-1\n"),
        fx("virsh-system-pools", 0, " Name      State\n default   running\n")
      ]

      f = Facts.extract(set(healthy))
      assert f["zfs.kernel_above_max"] == false
      assert f["zfs.module_present"] == true
      assert f["zfs.dkms_built"] == true
      assert f["zfs.pools_unavailable"] == false
      assert f["zfs.import_enabled"] == false
      assert f["zfs.headers_match_kernel"] == false
      assert f["zfs.newer_available"] == false
      assert f["libvirt.pool_inactive"] == false
    end
  end

  test "matching packages but a different running kernel (upgraded, not rebooted)" do
    f =
      Facts.extract(
        set([
          fx("uname", 0, "Linux h 7.1.9-arch1-1 x\n"),
          fx("pacman-kernel-zfs", 0, "linux 7.2.14.arch1-1\nlinux-headers 7.2.14.arch1-1\n")
        ])
      )

    assert f["zfs.headers_match_kernel"] == false
  end

  test "zpool failing for another reason is not the module being unavailable" do
    f = Facts.extract(set([fx("zpool-status", 1, "", "cannot open 'tank': no such pool\n")]))
    assert f["zfs.pools_unavailable"] == false
  end

  test "missing fixtures leave their facts out instead of guessing" do
    f = Facts.extract(set([fx("uname", 0, "Linux h 7.2.14-arch1-1 x\n")]))
    assert f["kernel.running"] == "7.2.14"

    for name <-
          ~w(zfs.linux_max zfs.kernel_above_max zfs.module_present zfs.dkms_built zfs.pools_unavailable
                   zfs.import_enabled zfs.headers_match_kernel zfs.newer_available libvirt.pool_inactive) do
      refute Map.has_key?(f, name), "#{name} guessed without its fixture"
    end

    assert Facts.extract(set([])) == %{}
  end

  test "a fixture that could not run gives no fact" do
    not_run = %Fixture{fx("modinfo-zfs", -1, "") | error: "ssh failed", timed_out: false}
    refute Map.has_key?(Facts.extract(set([not_run])), "zfs.module_present")
  end

  test "sources/1 names the fixtures behind a fact" do
    assert Facts.sources("zfs.kernel_above_max") == ["uname", "zfs-dkms-meta"]
    assert Facts.sources("zfs.module_present") == ["modinfo-zfs"]
    assert Facts.sources("zfs.headers_match_kernel") == ["pacman-kernel-zfs", "uname"]
    assert Facts.sources("no.such.fact") == []
  end

  test "compare/2" do
    assert Facts.compare("7.2.14", "6.18") == :gt
    assert Facts.compare("6.18", "6.18.0") == :eq
    assert Facts.compare("6.9", "6.18") == :lt
    assert Facts.compare("7.2.14-arch1-1", "7.2.14") == :eq
    assert Facts.compare("7.2.14.arch1-1", "7.2.14") == :eq
    assert Facts.compare("2.4.4", "2.4.0") == :gt
  end

  describe "kubelet, IPMI and LAN facts" do
    @kubelet_status "* kubelet.service - The Kubernetes Node Agent\n     Loaded: loaded (/usr/lib/systemd/system/kubelet.service; enabled; preset: disabled)\n     Active: activating (auto-restart) (Result: exit-code) since Sun 2026-11-08 18:38:56 UTC; 4s ago\n"
    @kubelet_journal ~s|2026-11-08T18:38:55+00:00 labhost (kubelet)[1]: kubelet.service: Referenced but unset environment variable evaluates to an empty string: KUBELET_KUBEADM_ARGS\n2026-11-08T18:38:56+00:00 labhost kubelet[1]: E1108 run.go:72] "command failed" err="failed to load kubelet config file, path: /var/lib/kubelet/config.yaml, error: open /var/lib/kubelet/config.yaml: no such file or directory"\n|
    @lsmod "Module                  Size  Used by\nipmi_ssif              49152  0\nipmi_si               102400  1\nipmi_devintf           24576  0\nipmi_msghandler        94208  4 ipmi_devintf,ipmi_si\n"
    @ethtool "Settings for eno25:\n\tSupported link modes:   10baseT/Half 10baseT/Full\n\tAdvertised link modes:  10baseT/Half 10baseT/Full\n\t                        100baseT/Half 100baseT/Full\n\t                        1000baseT/Full\n\tAdvertised pause frame use: Symmetric\n\tSpeed: 100Mb/s\n\tDuplex: Full\n\tAuto-negotiation: on\n\tLink detected: yes\n"

    test "the recorded failure shapes" do
      f =
        Facts.extract(
          set([
            fx("systemctl-kubelet", 3, @kubelet_status),
            fx("journal-kubelet", 0, @kubelet_journal),
            fx(
              "ipmi-sdr",
              1,
              "",
              "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0: No such file or directory\n"
            ),
            fx("lsmod", 0, @lsmod),
            fx("ethtool-eno25", 0, @ethtool, "netlink error: Operation not permitted\n")
          ])
        )

      assert f["k8s.kubelet_failing"] == true
      assert f["k8s.kubelet_config_missing"] == true
      assert f["k8s.kubeadm_flags_unset"] == true
      assert f["k8s.swap_error"] == false
      assert f["k8s.runtime_error"] == false
      assert f["k8s.cgroup_error"] == false
      assert f["ipmi.unreachable"] == true
      assert f["ipmi.device_missing"] == true
      assert f["ipmi.permission_denied"] == false
      assert f["ipmi.si_loaded"] == true
      assert f["ipmi.devintf_loaded"] == true
      assert f["net.lan_speed_mbps"] == 100
      assert f["net.lan_max_advertised_mbps"] == 1000
      assert f["net.lan_below_advertised"] == true
      assert f["net.lan_duplex_full"] == true
      assert f["net.lan_autoneg"] == true
    end

    test "the healthy shapes" do
      f =
        Facts.extract(
          set([
            fx(
              "systemctl-kubelet",
              0,
              String.replace(
                @kubelet_status,
                "activating (auto-restart) (Result: exit-code)",
                "active (running)"
              )
            ),
            fx(
              "journal-kubelet",
              0,
              "2026-11-08T00:00:00+00:00 labhost kubelet[1]: I1108 started\n"
            ),
            fx("ipmi-sdr", 0, "CPU Temp | 30 degrees C | ok\n"),
            fx("lsmod", 0, "Module Size Used by\nloop 1 0\n"),
            fx(
              "ethtool-eno25",
              0,
              String.replace(@ethtool, "100Mb/s", "1000Mb/s")
              |> String.replace("Duplex: Full", "Duplex: Half")
              |> String.replace("Auto-negotiation: on", "Auto-negotiation: off")
            )
          ])
        )

      assert f["k8s.kubelet_failing"] == false
      assert f["k8s.kubelet_config_missing"] == false
      assert f["k8s.kubeadm_flags_unset"] == false
      assert f["ipmi.unreachable"] == false
      assert f["ipmi.device_missing"] == false
      assert f["ipmi.si_loaded"] == false
      assert f["ipmi.devintf_loaded"] == false
      assert f["net.lan_speed_mbps"] == 1000
      assert f["net.lan_below_advertised"] == false
      assert f["net.lan_duplex_full"] == false
      assert f["net.lan_autoneg"] == false
    end

    test "other kubelet failures and IPMI permission" do
      journal =
        "kubelet[1]: E1108 \"command failed\" err=\"failed to run Kubelet: running with swap on is not supported, please disable swap\"\n" <>
          "kubelet[1]: E1108 \"Container runtime network not ready\" err=\"rpc error: dial unix /run/containerd/containerd.sock: connect: connection refused\"\n" <>
          "kubelet[1]: E1108 err=\"failed to run Kubelet: misconfiguration: kubelet cgroup driver: \\\"systemd\\\" is different from docker cgroup driver: \\\"cgroupfs\\\"\"\n"

      f =
        Facts.extract(
          set([
            fx("journal-kubelet", 0, journal),
            fx("ipmi-sdr", 1, "", "Could not open device at /dev/ipmi0: Permission denied\n")
          ])
        )

      assert f["k8s.swap_error"] == true
      assert f["k8s.runtime_error"] == true
      assert f["k8s.cgroup_error"] == true
      assert f["k8s.kubelet_config_missing"] == false
      assert f["ipmi.permission_denied"] == true
      assert f["ipmi.device_missing"] == false
    end

    test "unknowns stay out" do
      f =
        Facts.extract(
          set([
            fx("systemctl-kubelet", 4, "Unit kubelet.service could not be found.\n"),
            fx(
              "ethtool-eno25",
              0,
              "Settings for eno25:\n\tSpeed: Unknown!\n\tLink detected: no\n"
            )
          ])
        )

      refute Map.has_key?(f, "k8s.kubelet_failing")
      refute Map.has_key?(f, "k8s.kubelet_config_missing")
      refute Map.has_key?(f, "ipmi.unreachable")
      refute Map.has_key?(f, "net.lan_speed_mbps")
      refute Map.has_key?(f, "net.lan_below_advertised")
      refute Map.has_key?(f, "net.lan_max_advertised_mbps")
    end
  end

  # The plan's validation case: the real (scrubbed) fixtures from the server,
  # scored with the shipped ZFS rule, must rank the kernel mismatch first.
  @public Path.expand("../../../../fixtures/public/zfs-down-2026-11-04", __DIR__)
  test "real fixtures + shipped rule rank the kernel/zfs-dkms mismatch first" do
    {:ok, set} = Fixtures.load(@public)
    {:ok, rules} = Diagnosis.load_all(Application.app_dir(:lightpath, "priv/rules"))
    facts = Facts.extract(set)
    rule = Enum.find(rules, &(&1.id == "zfs-pools-unavailable" and Diagnosis.applies?(&1, facts)))
    assert rule, "no rule applies to the recorded ZFS failure"
    [first, second | _] = Diagnosis.score(rule, facts)
    assert first.id == "kernel-unsupported"
    assert first.probability > second.probability
    assert first.contributions != []
  end

  @up Path.expand("../../../../fixtures/public/zfs-up-2026-11-08", __DIR__)

  defp ranked(set_dir) do
    {:ok, set} = Fixtures.load(set_dir)
    {:ok, rules} = Diagnosis.load_all(Application.app_dir(:lightpath, "priv/rules"))
    facts = Facts.extract(set)

    for rule <- rules, Diagnosis.applies?(rule, facts), into: %{} do
      {rule.id, Enum.map(Diagnosis.score(rule, facts), & &1.id)}
    end
  end

  test "real fixtures: every shipped rule fires where it should, with the expected leader" do
    down = ranked(@public)
    up = ranked(@up)

    assert hd(down["zfs-pools-unavailable"]) == "kernel-unsupported"
    refute Map.has_key?(up, "zfs-pools-unavailable"), "ZFS works in the 2026-11-08 set"

    for r <- [down, up] do
      assert hd(r["kubelet-down"]) == "not-initialized"
      assert hd(r["ipmi-unavailable"]) == "node-not-created"
      assert hd(r["lan-slow"]) in ["cable", "partner-port"]
    end
  end
end
