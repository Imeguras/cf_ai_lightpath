package inventory

// DefaultCommands returns the phase 1 inventory list.
//
// Every entry passes Validate and none escalates privileges; commands that
// need root are expected to fail and that failure is the evidence. The list
// covers the OS and kernel, packages (repo packages through pacman, AUR
// packages through paru), ZFS, systemd units and the journal, disks, network
// and the ConnectX-3 Pro, sensors and IPMI, libvirt, Kubernetes, Docker and
// PCP. It includes at least the IDs used by the ZFS validation case: uname,
// pacman-q, pacman-kernel-zfs, pacman-foreign, paru-aur-info-zfs,
// zfs-dkms-meta, dkms-status, modinfo-zfs, zpool-status and
// virsh-system-pools.
//
// pacman and paru are only used to query: their first argument is --version,
// a query (-Q...), a show (-P...) or an info lookup (-S... with i, never with
// y, u or w), so nothing is synced, downloaded, built or installed. The paru
// AUR lookups do contact the AUR over the network.
//
// Each call returns a fresh slice, so callers may modify it.
func DefaultCommands() []Command {
	c := func(id, why string, argv ...string) Command { return Command{ID: id, Argv: argv, Why: why} }
	return []Command{
		// OS and kernel
		c("os-release", "distribution identity", "cat", "/etc/os-release"),
		c("uname", "running kernel version", "uname", "-a"),
		c("uptime", "how long since the last boot", "uptime"),
		c("modules-dirs", "kernels with installed module trees (installed but not booted)", "ls", "-1", "/usr/lib/modules"),
		c("lsmod", "loaded kernel modules", "lsmod"),
		c("lscpu", "CPU topology", "lscpu", "-J"),
		c("free", "memory and swap", "free", "-b"),

		// Packages
		c("pacman-q", "all installed packages and versions (Arch news matching)", "pacman", "-Q"),
		c("pacman-kernel-zfs", "kernel, headers and ZFS package versions side by side", "pacman", "-Q",
			"linux", "linux-headers", "linux-lts", "linux-lts-headers", "zfs-dkms", "zfs-utils"),
		c("pacman-qi-zfs-dkms", "zfs-dkms package details and dependencies", "pacman", "-Qi", "zfs-dkms"),
		c("pacman-qi-zfs-utils", "zfs-utils package details and dependencies", "pacman", "-Qi", "zfs-utils"),
		c("pacman-foreign", "packages not from the official repos (AUR or manual installs)", "pacman", "-Qm"),

		// AUR (paru; the lookups below query the AUR over the network)
		c("paru-version", "paru and libalpm versions", "paru", "--version"),
		c("paru-aur-upgrades", "AUR packages with a newer version on the AUR", "paru", "-Qua"),
		c("paru-aur-info-zfs", "latest AUR zfs-dkms/zfs-utils: is there one that supports the running kernel?",
			"paru", "-Sai", "zfs-dkms", "zfs-utils"),
		c("paru-stats", "package counts, including foreign packages", "paru", "-Ps"),

		// ZFS
		c("zfs-dkms-meta", "kernel range the installed ZFS source supports (Linux-Minimum/Maximum)",
			"find", "/usr/src", "-maxdepth", "2", "-path", "/usr/src/zfs-*/META", "-exec", "cat", "{}", "+"),
		c("dkms-status", "which kernels the zfs module was built for", "dkms", "status"),
		c("modinfo-zfs", "whether a zfs module exists for the running kernel", "modinfo", "zfs"),
		c("zpool-status", "pool health (fails while the module is missing)", "zpool", "status"),
		c("zpool-list", "pool capacity", "zpool", "list"),
		c("zfs-list", "datasets", "zfs", "list"),

		// systemd and journal
		c("systemctl-failed", "units in failed state", "systemctl", "--failed", "--no-pager", "--plain"),
		c("systemctl-zfs", "ZFS import and mount units", "systemctl", "status", "--no-pager",
			"zfs-import-cache.service", "zfs-import-scan.service", "zfs-mount.service", "zfs.target"),
		c("systemctl-kubelet", "kubelet unit state", "systemctl", "status", "--no-pager", "kubelet.service"),
		c("journal-warnings", "warnings and errors this boot", "journalctl", "-b", "-p", "warning", "--no-pager", "-n", "1000", "-o", "short-iso"),
		c("journal-kernel", "kernel log this boot (dmesg via the journal)", "journalctl", "-k", "-b", "--no-pager", "-n", "1000", "-o", "short-iso"),
		c("journal-zfs", "ZFS unit logs this boot", "journalctl", "-b", "--no-pager", "-n", "300", "-o", "short-iso",
			"-u", "zfs-import-cache.service", "-u", "zfs-import-scan.service", "-u", "zfs-mount.service"),
		c("journal-kubelet", "why kubelet is stuck activating", "journalctl", "-b", "--no-pager", "-n", "300", "-o", "short-iso", "-u", "kubelet.service"),
		c("dmesg", "whether dmesg is restricted for unprivileged users", "dmesg", "--time-format", "iso"),

		// Disks
		c("lsblk", "block devices and filesystems", "lsblk", "-J", "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL"),
		c("df", "filesystem usage", "df", "-hT"),
		c("smartctl-scan", "disks visible to smartctl (details need root)", "smartctl", "--scan"),

		// Network and ConnectX-3 Pro
		c("ip-link", "interfaces and link state", "ip", "-j", "link"),
		c("ip-addr", "addresses", "ip", "-j", "addr"),
		c("ethtool-eno25", "LAN port negotiated speed (only 100 Mb/s?)", "ethtool", "eno25"),
		c("ethtool-eno25-driver", "LAN port driver and firmware", "ethtool", "-i", "eno25"),
		c("ethtool-ens9d1", "ConnectX-3 Pro Ethernet port link state", "ethtool", "ens9d1"),
		c("ethtool-ens9d1-driver", "ConnectX-3 Pro driver and firmware", "ethtool", "-i", "ens9d1"),
		c("ethtool-ens9d1-stats", "ConnectX-3 Pro Ethernet port counters", "ethtool", "-S", "ens9d1"),
		c("ethtool-ens9d1-module", "transceiver/optic readings (may need root)", "ethtool", "-m", "ens9d1"),
		c("lspci-mellanox", "Mellanox devices and PCI IDs", "lspci", "-nn", "-d", "15b3:"),
		c("lspci-mellanox-verbose", "Mellanox PCIe link width and speed (partial without root)", "lspci", "-vv", "-d", "15b3:"),
		// Searches /sys/devices without following symlinks: the /sys/class
		// view loops back on itself through device/, which makes find -L fail.
		c("ib-sysfs", "InfiniBand port state, physical state, rate and link layer from sysfs",
			"find", "/sys/devices", "-path", "*/infiniband/*/ports/*",
			"(", "-name", "state", "-o", "-name", "phys_state", "-o", "-name", "rate", "-o", "-name", "link_layer", ")",
			"-exec", "grep", "-H", ".", "{}", "+"),
		c("ibstat", "InfiniBand HCA and port summary (infiniband-diags)", "ibstat"),

		// Sensors and IPMI
		c("sensors", "temperatures, fans and voltages", "sensors", "-j"),
		c("ipmi-sdr", "BMC sensor records (expected to fail: /dev/ipmi0 is root-only)", "ipmitool", "sdr"),

		// libvirt (read-only connections)
		c("virsh-system-list", "system VMs and their state", "virsh", "-r", "-c", "qemu:///system", "list", "--all"),
		c("virsh-system-pools", "storage pools (ZFS-backed ones fail to start)", "virsh", "-r", "-c", "qemu:///system", "pool-list", "--all", "--details"),
		c("virsh-system-nets", "libvirt networks", "virsh", "-r", "-c", "qemu:///system", "net-list", "--all"),
		c("virsh-session-list", "session VMs (usually empty; empty is normal, not a fault)", "virsh", "-r", "-c", "qemu:///session", "list", "--all"),

		// Kubernetes, Docker, PCP
		c("kubectl-version", "kubectl client version", "kubectl", "version", "--client", "-o", "json"),
		c("docker-ps", "containers and their state", "docker", "ps", "-a", "--no-trunc", "--format", "json"),
		c("docker-security", "daemon security options: shows \"name=rootless\" when Docker runs rootless",
			"docker", "info", "--format", "{{json .SecurityOptions}}"),
		c("pminfo", "metric names PCP provides (PMDAs present)", "pminfo"),
	}
}
