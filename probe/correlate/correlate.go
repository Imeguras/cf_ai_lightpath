// Package correlate decides which read-only probes an event makes worth
// re-running, and batches bursts of events (one pacman -Syu is hundreds of
// package events) into one probe run.
package correlate

import (
	"regexp"
	"slices"
	"time"

	"lightpath/probe/events"
)

// Rule: events of Kind whose Subject matches Subject (and whose Change is
// Change, when that is not empty) make Probes worth re-running.
type Rule struct {
	Kind    events.Kind
	Subject *regexp.Regexp
	Change  string
	Probes  []string
	Why     string
}

// DefaultRules is the shipped rule set. Every probe id it names exists in
// inventory.DefaultCommands.
func DefaultRules() []Rule {
	re := func(p string) *regexp.Regexp { return regexp.MustCompile(p) }
	zfs := []string{"uname", "modules-dirs", "lsmod", "pacman-kernel-zfs", "pacman-qi-zfs-dkms",
		"pacman-qi-zfs-utils", "zfs-dkms-meta", "dkms-status", "modinfo-zfs", "paru-aur-info-zfs"}
	return []Rule{
		{Kind: events.Package, Subject: re(`.*`), Probes: []string{"pacman-q", "pacman-foreign", "paru-aur-upgrades"},
			Why: "any package change changes the installed list"},
		{Kind: events.Package, Subject: re(`linux(-lts|-zen|-hardened)?(-headers)?|zfs-dkms|zfs-utils|dkms`), Probes: zfs,
			Why: "kernel and ZFS packages move together; a mismatch takes the pools down"},
		{Kind: events.Package, Subject: re(`kubeadm|kubelet|kubectl|containerd|cri-tools|runc`),
			Probes: []string{"kubectl-version", "systemctl-kubelet", "journal-kubelet"},
			Why:    "Kubernetes and its runtime"},
		{Kind: events.Package, Subject: re(`ipmitool|freeipmi`), Probes: []string{"ipmi-sdr"}, Why: "IPMI tools"},
		{Kind: events.Package, Subject: re(`libvirt|qemu.*`),
			Probes: []string{"virsh-system-list", "virsh-system-pools", "virsh-system-nets"}, Why: "virtualisation stack"},
		{Kind: events.Unit, Subject: re(`.*`), Change: "failed", Probes: []string{"systemctl-failed", "journal-warnings"},
			Why: "any unit failing"},
		{Kind: events.Unit, Subject: re(`kubelet\.service|containerd\.service`),
			Probes: []string{"systemctl-kubelet", "journal-kubelet"}, Why: "kubelet state"},
		{Kind: events.Unit, Subject: re(`zfs.*`),
			Probes: []string{"systemctl-zfs", "journal-zfs", "zpool-status", "zpool-list", "zfs-list", "virsh-system-pools"},
			Why:    "ZFS import and mount units"},
		{Kind: events.Unit, Subject: re(`libvirtd.*|virt.*`),
			Probes: []string{"virsh-system-list", "virsh-system-pools", "virsh-system-nets"}, Why: "libvirt"},
		{Kind: events.Unit, Subject: re(`docker\.service|docker\.socket`), Probes: []string{"docker-ps", "docker-security"},
			Why: "Docker"},
		{Kind: events.Kernel, Subject: re(`.*`), Change: "link-up",
			Probes: []string{"ip-link", "ip-addr", "ethtool-eno25", "ethtool-ens9d1", "ib-sysfs", "ibstat"}, Why: "a link came up"},
		{Kind: events.Kernel, Subject: re(`.*`), Change: "link-down",
			Probes: []string{"ip-link", "ip-addr", "ethtool-eno25", "ethtool-ens9d1", "ib-sysfs", "ibstat"}, Why: "a link went down"},
		{Kind: events.Kernel, Subject: re(`kernel`), Probes: []string{"journal-kernel", "journal-warnings", "lsmod"},
			Why: "kernel warnings and errors"},
	}
}

// Probes returns the probe ids of every rule that matches e, without
// duplicates, sorted. A Subject pattern must match the whole subject.
func Probes(rules []Rule, e events.Event) []string {
	var ids []string
	for _, r := range rules {
		if r.Kind != e.Kind || (r.Change != "" && r.Change != e.Change) {
			continue
		}
		if loc := r.Subject.FindStringIndex(e.Subject); loc != nil && loc[0] == 0 && loc[1] == len(e.Subject) {
			ids = append(ids, r.Probes...)
		}
	}
	slices.Sort(ids)
	return slices.Compact(ids)
}

// Debouncer collects probe ids and releases them as one batch once events
// have stopped arriving for Quiet, or MaxWait after the first id of the batch
// arrived, whichever comes first. The zero value is not usable; set both
// durations.
type Debouncer struct {
	Quiet   time.Duration
	MaxWait time.Duration

	pending     map[string]bool
	first, last time.Time
}

// Add records ids as wanted at time now. Adding no ids changes nothing.
func (d *Debouncer) Add(ids []string, now time.Time) {
	if len(ids) == 0 {
		return
	}
	if len(d.pending) == 0 {
		d.pending = map[string]bool{}
		d.first = now
	}
	for _, id := range ids {
		d.pending[id] = true
	}
	d.last = now
}

// Due returns the pending ids, sorted and without duplicates, and forgets
// them, when the batch is due at now (see Debouncer); otherwise nil, and
// the batch stays pending.
func (d *Debouncer) Due(now time.Time) []string {
	if len(d.pending) == 0 || (now.Sub(d.last) < d.Quiet && now.Sub(d.first) < d.MaxWait) {
		return nil
	}
	ids := make([]string, 0, len(d.pending))
	for id := range d.pending {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	d.pending = nil
	return ids
}

// Pending returns the ids waiting in the current batch, sorted (nil when
// none), without releasing them.
func (d *Debouncer) Pending() []string {
	if len(d.pending) == 0 {
		return nil
	}
	ids := make([]string, 0, len(d.pending))
	for id := range d.pending {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}
