package correlate_test

import (
	"regexp"
	"slices"
	"testing"
	"time"

	"lightpath/probe/correlate"
	"lightpath/probe/events"
	"lightpath/probe/inventory"
)

func ev(kind events.Kind, subject, change string) events.Event {
	return events.Event{Kind: kind, Subject: subject, Change: change}
}

func TestDefaultRulesNameRealProbes(t *testing.T) {
	known := map[string]bool{}
	for _, c := range inventory.DefaultCommands() {
		known[c.ID] = true
	}
	rules := correlate.DefaultRules()
	if len(rules) == 0 {
		t.Fatal("no rules")
	}
	for _, r := range rules {
		if r.Why == "" || len(r.Probes) == 0 || r.Subject == nil {
			t.Errorf("incomplete rule %+v", r)
		}
		for _, p := range r.Probes {
			if !known[p] {
				t.Errorf("rule %q names unknown probe %q", r.Why, p)
			}
		}
	}
}

func TestDefaultRulesCoverTheKnownProblems(t *testing.T) {
	rules := correlate.DefaultRules()
	cases := []struct {
		e    events.Event
		must []string
	}{
		{ev(events.Package, "linux", "upgraded"), []string{"uname", "zfs-dkms-meta", "dkms-status", "modinfo-zfs", "pacman-q"}},
		{ev(events.Package, "zfs-dkms", "upgraded"), []string{"zfs-dkms-meta", "dkms-status", "modinfo-zfs"}},
		{ev(events.Package, "vim", "installed"), []string{"pacman-q"}},
		{ev(events.Package, "kubelet", "upgraded"), []string{"kubectl-version", "systemctl-kubelet"}},
		{ev(events.Unit, "kubelet.service", "failed"), []string{"systemctl-kubelet", "journal-kubelet", "systemctl-failed"}},
		{ev(events.Unit, "zfs-import-cache.service", "failed"), []string{"systemctl-zfs", "zpool-status"}},
		{ev(events.Kernel, "eno25", "link-up"), []string{"ethtool-eno25", "ip-link"}},
		{ev(events.Kernel, "kernel", "error"), []string{"journal-kernel"}},
	}
	for _, c := range cases {
		got := correlate.Probes(rules, c.e)
		for _, p := range c.must {
			if !slices.Contains(got, p) {
				t.Errorf("%+v: missing %q in %v", c.e, p, got)
			}
		}
	}
	if got := correlate.Probes(rules, ev(events.Unit, "user@1000.service", "started")); len(got) != 0 {
		t.Errorf("a routine unit start re-probes %v", got)
	}
}

func TestProbesMatching(t *testing.T) {
	rules := []correlate.Rule{
		{Kind: events.Package, Subject: regexp.MustCompile(`linux`), Probes: []string{"b", "a"}, Why: "1"},
		{Kind: events.Package, Subject: regexp.MustCompile(`.*`), Probes: []string{"a", "c"}, Why: "2"},
		{Kind: events.Unit, Subject: regexp.MustCompile(`.*`), Change: "failed", Probes: []string{"f"}, Why: "3"},
	}
	if got := correlate.Probes(rules, ev(events.Package, "linux", "upgraded")); !slices.Equal(got, []string{"a", "b", "c"}) {
		t.Errorf("linux: %v", got)
	}
	if got := correlate.Probes(rules, ev(events.Package, "linux-lts", "upgraded")); !slices.Equal(got, []string{"a", "c"}) {
		t.Errorf("subject must match whole: %v", got)
	}
	if got := correlate.Probes(rules, ev(events.Unit, "x", "started")); got != nil && len(got) != 0 {
		t.Errorf("change filter: %v", got)
	}
	if got := correlate.Probes(rules, ev(events.Unit, "x", "failed")); !slices.Equal(got, []string{"f"}) {
		t.Errorf("failed: %v", got)
	}
	if got := correlate.Probes(rules, ev(events.Kernel, "linux", "error")); len(got) != 0 {
		t.Errorf("kind must match: %v", got)
	}
}

var t0 = time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)

func TestDebounceQuiet(t *testing.T) {
	d := &correlate.Debouncer{Quiet: 30 * time.Second, MaxWait: 5 * time.Minute}
	if d.Due(t0) != nil {
		t.Fatal("empty debouncer is due")
	}
	d.Add([]string{"b", "a"}, t0)
	d.Add([]string{"a", "c"}, t0.Add(10*time.Second))
	if got := d.Due(t0.Add(39 * time.Second)); got != nil {
		t.Fatalf("due before quiet: %v", got)
	}
	if got := d.Due(t0.Add(40 * time.Second)); !slices.Equal(got, []string{"a", "b", "c"}) {
		t.Fatalf("due = %v", got)
	}
	if got := d.Due(t0.Add(41 * time.Second)); got != nil {
		t.Fatalf("batch not forgotten: %v", got)
	}
}

func TestDebounceMaxWait(t *testing.T) {
	d := &correlate.Debouncer{Quiet: 30 * time.Second, MaxWait: 2 * time.Minute}
	for i := 0; i <= 12; i++ { // an event every 10 s: never quiet
		d.Add([]string{"p"}, t0.Add(time.Duration(i)*10*time.Second))
		if i < 12 && d.Due(t0.Add(time.Duration(i)*10*time.Second)) != nil {
			t.Fatalf("due early at %d", i)
		}
	}
	if got := d.Due(t0.Add(2 * time.Minute)); !slices.Equal(got, []string{"p"}) {
		t.Fatalf("max wait: %v", got)
	}
	d.Add([]string{"q"}, t0.Add(3*time.Minute))
	if got := d.Due(t0.Add(3*time.Minute + 29*time.Second)); got != nil {
		t.Fatalf("new batch due early: %v", got)
	}
}

func TestDebounceEmptyAdd(t *testing.T) {
	d := &correlate.Debouncer{Quiet: time.Second, MaxWait: time.Minute}
	d.Add(nil, t0)
	if d.Due(t0.Add(time.Hour)) != nil {
		t.Fatal("empty add made a batch")
	}
	d.Add([]string{"a"}, t0)
	d.Add(nil, t0.Add(500*time.Millisecond)) // does not extend quiet
	if got := d.Due(t0.Add(time.Second)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("got %v", got)
	}
}

func TestPending(t *testing.T) {
	d := &correlate.Debouncer{Quiet: time.Minute, MaxWait: time.Hour}
	if d.Pending() != nil {
		t.Fatal("pending on empty")
	}
	d.Add([]string{"b", "a", "b"}, t0)
	if got := d.Pending(); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("pending %v", got)
	}
	if got := d.Due(t0.Add(time.Minute)); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("Pending released the batch: %v", got)
	}
}
