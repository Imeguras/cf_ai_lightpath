defmodule Lightpath.Diagnosis.Facts do
  @moduledoc """
  Turns a fixture set into named facts for `Lightpath.Diagnosis`.

  Each fact comes from one or two fixtures and is left out when those
  fixtures are missing or do not contain what the parser needs, so an
  unknown fact is never mistaken for a false one.

  | Fact | From | Meaning |
  |---|---|---|
  | `kernel.running` | `uname` | running kernel version, e.g. `"7.2.14"` |
  | `zfs.dkms_version` | `zfs-dkms-meta` | ZFS source version (`Version:`) |
  | `zfs.linux_max` | `zfs-dkms-meta` | newest supported kernel (`Linux-Maximum:`) |
  | `zfs.kernel_above_max` | both above | running kernel's major.minor is above `Linux-Maximum` |
  | `zfs.module_present` | `modinfo-zfs` | a zfs module exists for the running kernel (exit 0) |
  | `zfs.dkms_built` | `dkms-status` | some `zfs/...` line says `installed` |
  | `zfs.pools_unavailable` | `zpool-status` | zpool could not talk to the module (exit non-zero with "modules" in stderr) |
  | `zfs.import_enabled` | `systemctl-zfs` | `zfs-import-cache.service` is `enabled` |
  | `zfs.headers_match_kernel` | `pacman-kernel-zfs`, `uname` | `linux-headers` has the same version as `linux`, and `linux` matches the running kernel |
  | `zfs.newer_available` | `paru-aur-info-zfs`, `zfs-dkms-meta` | the AUR has a newer zfs-dkms than the installed one |
  | `libvirt.pool_inactive` | `virsh-system-pools` | at least one storage pool is `inactive` |
  | `k8s.kubelet_failing` | `systemctl-kubelet` | its `Active:` line is anything but `active (running)` |
  | `k8s.kubelet_config_missing` | `journal-kubelet` | kubelet could not read `/var/lib/kubelet/config.yaml` (no such file) |
  | `k8s.kubeadm_flags_unset` | `journal-kubelet` | `KUBELET_KUBEADM_ARGS` is unset (kubeadm never wrote its flags file) |
  | `k8s.swap_error` | `journal-kubelet` | kubelet refused to run with swap on |
  | `k8s.runtime_error` | `journal-kubelet` | kubelet could not reach the container runtime |
  | `k8s.cgroup_error` | `journal-kubelet` | kubelet reported a cgroup driver problem |
  | `ipmi.unreachable` | `ipmi-sdr` | `ipmitool` failed (non-zero exit) |
  | `ipmi.device_missing` | `ipmi-sdr` | it failed because no IPMI device node exists (`No such file or directory`) |
  | `ipmi.permission_denied` | `ipmi-sdr` | it failed with `Permission denied` |
  | `ipmi.si_loaded` | `lsmod` | the `ipmi_si` module (BMC interface driver) is loaded |
  | `ipmi.devintf_loaded` | `lsmod` | the `ipmi_devintf` module (creates `/dev/ipmi0`) is loaded |
  | `net.lan_speed_mbps` | `ethtool-eno25` | negotiated speed in Mb/s (`Speed:`) |
  | `net.lan_max_advertised_mbps` | `ethtool-eno25` | fastest mode this port advertises, in Mb/s |
  | `net.lan_below_advertised` | `ethtool-eno25` | the negotiated speed is below the fastest advertised mode |
  | `net.lan_duplex_full` | `ethtool-eno25` | `Duplex: Full` |
  | `net.lan_autoneg` | `ethtool-eno25` | `Auto-negotiation: on` |

  The journal facts are false (not unknown) when the journal was read and
  the message is absent.
  """

  alias Lightpath.Fixtures

  @sources %{
    "kernel.running" => ["uname"],
    "zfs.dkms_version" => ["zfs-dkms-meta"],
    "zfs.linux_max" => ["zfs-dkms-meta"],
    "zfs.kernel_above_max" => ["uname", "zfs-dkms-meta"],
    "zfs.module_present" => ["modinfo-zfs"],
    "zfs.dkms_built" => ["dkms-status"],
    "zfs.pools_unavailable" => ["zpool-status"],
    "zfs.import_enabled" => ["systemctl-zfs"],
    "zfs.headers_match_kernel" => ["pacman-kernel-zfs", "uname"],
    "zfs.newer_available" => ["paru-aur-info-zfs", "zfs-dkms-meta"],
    "libvirt.pool_inactive" => ["virsh-system-pools"],
    "k8s.kubelet_failing" => ["systemctl-kubelet"],
    "k8s.kubelet_config_missing" => ["journal-kubelet"],
    "k8s.kubeadm_flags_unset" => ["journal-kubelet"],
    "k8s.swap_error" => ["journal-kubelet"],
    "k8s.runtime_error" => ["journal-kubelet"],
    "k8s.cgroup_error" => ["journal-kubelet"],
    "ipmi.unreachable" => ["ipmi-sdr"],
    "ipmi.device_missing" => ["ipmi-sdr"],
    "ipmi.permission_denied" => ["ipmi-sdr"],
    "ipmi.si_loaded" => ["lsmod"],
    "ipmi.devintf_loaded" => ["lsmod"],
    "net.lan_speed_mbps" => ["ethtool-eno25"],
    "net.lan_max_advertised_mbps" => ["ethtool-eno25"],
    "net.lan_below_advertised" => ["ethtool-eno25"],
    "net.lan_duplex_full" => ["ethtool-eno25"],
    "net.lan_autoneg" => ["ethtool-eno25"]
  }
  alias Lightpath.Fixtures.Set

  @doc "Extracts every fact it can from `set`, as a map of fact name to value."
  @spec extract(Set.t()) :: %{optional(String.t()) => term()}
  def extract(%Set{} = set) do
    ran = fn id ->
      case Fixtures.get(set, id) do
        {:ok, f} -> if Fixtures.status(f) == :not_run, do: nil, else: f
        _ -> nil
      end
    end

    kernel =
      with %{} = f <- ran.("uname"),
           [_, _, release | _] <- String.split(f.stdout),
           do: numeric(release)

    meta = with %{} = f <- ran.("zfs-dkms-meta"), do: meta_fields(f.stdout)
    dkms_version = meta && meta["Version"]
    linux_max = meta && meta["Linux-Maximum"]

    [
      {"kernel.running", kernel},
      {"zfs.dkms_version", dkms_version},
      {"zfs.linux_max", linux_max},
      {"zfs.kernel_above_max",
       kernel && linux_max && compare(major_minor(kernel), linux_max) == :gt},
      {"zfs.module_present", with(%{} = f <- ran.("modinfo-zfs"), do: f.exit_code == 0)},
      {"zfs.dkms_built",
       with(
         %{} = f <- ran.("dkms-status"),
         do: Regex.match?(~r/^zfs\/.*:\s*installed/m, f.stdout)
       )},
      {"zfs.pools_unavailable",
       with(%{} = f <- ran.("zpool-status"), do: f.exit_code != 0 and f.stderr =~ "modules")},
      {"zfs.import_enabled",
       with(%{} = f <- ran.("systemctl-zfs"), do: import_enabled(f.stdout))},
      {"zfs.headers_match_kernel",
       with(%{} = f <- ran.("pacman-kernel-zfs"), do: headers_match(f.stdout, kernel))},
      {"zfs.newer_available",
       with(%{} = f <- ran.("paru-aur-info-zfs"), do: newer_available(f.stdout, dkms_version))},
      {"libvirt.pool_inactive",
       with(%{} = f <- ran.("virsh-system-pools"), do: f.stdout =~ ~r/\binactive\b/)}
    ]
    |> Kernel.++(kubelet_facts(ran.("systemctl-kubelet"), ran.("journal-kubelet")))
    |> Kernel.++(ipmi_facts(ran.("ipmi-sdr"), ran.("lsmod")))
    |> Kernel.++(lan_facts(ran.("ethtool-eno25")))
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp kubelet_facts(status, journal) do
    failing =
      with %{} = f <- status,
           [_, state] <- Regex.run(~r/^\s*Active:\s*(.+)$/m, f.stdout),
           do: not String.starts_with?(state, "active (running)")

    log = journal && journal.stdout

    in_log = fn re -> log && Regex.match?(re, log) end

    [
      {"k8s.kubelet_failing", failing},
      {"k8s.kubelet_config_missing",
       in_log.(~r{/var/lib/kubelet/config\.yaml: no such file or directory})},
      {"k8s.kubeadm_flags_unset", in_log.(~r/unset environment variable.*KUBELET_KUBEADM_ARGS/)},
      {"k8s.swap_error", in_log.(~r/running with swap on is not supported/i)},
      {"k8s.runtime_error",
       in_log.(
         ~r/container runtime.*(not ready|is down)|containerd\.sock.*(refused|no such file)/i
       )},
      {"k8s.cgroup_error", in_log.(~r/cgroup driver/i)}
    ]
  end

  defp ipmi_facts(sdr, lsmod) do
    loaded = fn mod -> lsmod && Regex.match?(~r/^#{mod}\s/m, lsmod.stdout) end

    [
      {"ipmi.unreachable", sdr && sdr.exit_code != 0},
      {"ipmi.device_missing",
       sdr && sdr.exit_code != 0 && sdr.stderr =~ ~r/No such file or directory/},
      {"ipmi.permission_denied",
       sdr && sdr.exit_code != 0 && sdr.stderr =~ ~r/permission denied/i},
      {"ipmi.si_loaded", loaded.("ipmi_si")},
      {"ipmi.devintf_loaded", loaded.("ipmi_devintf")}
    ]
  end

  defp lan_facts(nil), do: []

  defp lan_facts(f) do
    speed =
      case Regex.run(~r/^\s*Speed:\s*(\d+)Mb\/s/m, f.stdout) do
        [_, n] -> String.to_integer(n)
        nil -> nil
      end

    advertised =
      case Regex.run(~r/Advertised link modes:(.*?)\n\s*Advertised (?!link)/s, f.stdout) do
        [_, modes] ->
          Regex.scan(~r/(\d+)base/, modes)
          |> Enum.map(fn [_, n] -> String.to_integer(n) end)
          |> Enum.max(fn -> nil end)

        nil ->
          nil
      end

    [
      {"net.lan_speed_mbps", speed},
      {"net.lan_max_advertised_mbps", advertised},
      {"net.lan_below_advertised", speed && advertised && speed < advertised},
      {"net.lan_duplex_full",
       with([_, d] <- Regex.run(~r/^\s*Duplex:\s*(\w+)/m, f.stdout), do: d == "Full")},
      {"net.lan_autoneg",
       with([_, a] <- Regex.run(~r/^\s*Auto-negotiation:\s*(\w+)/m, f.stdout), do: a == "on")}
    ]
  end

  defp meta_fields(text) do
    for line <- String.split(text, "\n"),
        [k, v] <- [String.split(line, ":", parts: 2)],
        into: %{},
        do: {String.trim(k), String.trim(v)}
  end

  defp import_enabled(text) do
    case Regex.run(~r/zfs-import-cache\.service;\s*(\w+)/, text) do
      [_, state] -> state == "enabled"
      nil -> nil
    end
  end

  # nil when the listing lacks linux, linux-headers or the running kernel.
  defp headers_match(_text, nil), do: nil

  defp headers_match(text, kernel) do
    pkgs =
      for line <- String.split(text, "\n"), [n, v] <- [String.split(line)], into: %{}, do: {n, v}

    with linux when is_binary(linux) <- pkgs["linux"],
         headers when is_binary(headers) <- pkgs["linux-headers"] do
      headers == linux and compare(numeric(linux), kernel) == :eq
    else
      _ -> nil
    end
  end

  defp newer_available(_text, nil), do: nil

  defp newer_available(text, installed) do
    case Regex.run(~r/^Version\s*:\s*(\S+)/m, text) do
      [_, aur] -> compare(numeric(aur), installed) == :gt
      nil -> nil
    end
  end

  # The leading dotted-number part of a version: "7.2.14-arch1-1" -> "7.2.14".
  defp numeric(v) do
    case Regex.run(~r/^\d+(?:\.\d+)*/, v) do
      [n] -> n
      nil -> nil
    end
  end

  defp major_minor(v), do: v |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  @doc """
  The fixture ids a fact is read from (the "From" column above), so the UI can
  link evidence to its fixtures. Unknown facts give `[]`.
  """
  @spec sources(String.t()) :: [String.t()]
  def sources(fact), do: Map.get(@sources, fact, [])

  @doc """
  Compares two dotted version strings by their numeric components, padding
  the shorter with zeros: `compare("7.2.14", "6.18") == :gt`,
  `compare("6.18", "6.18.0") == :eq`. Anything after the leading digits and
  dots (`-arch1-1`, `.arch1`) is ignored.
  """
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt
  def compare(a, b) do
    {pa, pb} = {parts(a), parts(b)}
    len = max(length(pa), length(pb))
    pad = &(&1 ++ List.duplicate(0, len - length(&1)))

    case {pad.(pa), pad.(pb)} do
      {x, x} -> :eq
      {x, y} when x > y -> :gt
      _ -> :lt
    end
  end

  defp parts(v) do
    (numeric(v) || "0") |> String.split(".") |> Enum.map(&String.to_integer/1)
  end
end
