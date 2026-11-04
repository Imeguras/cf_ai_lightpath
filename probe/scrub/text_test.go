package scrub_test

import (
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"lightpath/probe/scrub"
)

// Invented values shaped like the real ones.
var testCfg = scrub.Config{Literals: []scrub.Literal{
	{Find: "box-alpha", Replace: "labhost"},
	{Find: "alice", Replace: "labuser"},
	{Find: "tank_main", Replace: "pool_a"},
	{Find: "bob", Replace: "friend", IgnoreCase: true},
}}

func newScrubber(t *testing.T) *scrub.Scrubber {
	t.Helper()
	s, err := scrub.New(testCfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return s
}

func TestNewRejectsBadLiterals(t *testing.T) {
	for name, lits := range map[string][]scrub.Literal{
		"empty find":         {{Find: "", Replace: "x"}},
		"empty replace":      {{Find: "alice", Replace: ""}},
		"replace has find":   {{Find: "alice", Replace: "alice2"}},
		"replace has other":  {{Find: "alice", Replace: "user"}, {Find: "bob", Replace: "alice-friend"}},
		"case-insens. clash": {{Find: "alice", Replace: "ALICE_X"}},
	} {
		if _, err := scrub.New(scrub.Config{Literals: lits}); err == nil {
			t.Errorf("%s: New = nil error, want error", name)
		}
	}
}

func TestNewAcceptsGoodConfig(t *testing.T) {
	if _, err := scrub.New(testCfg); err != nil {
		t.Fatalf("New(valid) = %v", err)
	}
	if _, err := scrub.New(scrub.Config{}); err != nil {
		t.Fatalf("New(empty config) = %v", err)
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	os.WriteFile(good, []byte(`{"literals":[{"find":"alice","replace":"labuser","ignore_case":true}],"drop":["journal-warnings"]}`), 0o600)
	cfg, err := scrub.LoadConfig(good)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if len(cfg.Literals) != 1 || cfg.Literals[0].Find != "alice" || !cfg.Literals[0].IgnoreCase || len(cfg.Drop) != 1 {
		t.Errorf("LoadConfig = %+v", cfg)
	}

	typo := filepath.Join(dir, "typo.json")
	os.WriteFile(typo, []byte(`{"literal":[{"find":"alice","replace":"x"}]}`), 0o600)
	if _, err := scrub.LoadConfig(typo); err == nil {
		t.Error("LoadConfig(unknown field) = nil error, want error")
	}
	if _, err := scrub.LoadConfig(filepath.Join(dir, "missing.json")); err == nil {
		t.Error("LoadConfig(missing file) = nil error, want error")
	}
}

func TestLiterals(t *testing.T) {
	s := newScrubber(t)
	cases := map[string]string{
		"host box-alpha up":           "host labhost up",
		"/home/alice/compose":         "/home/labuser/compose",
		"_alice_":                     "_labuser_",
		"alice@box-alpha":             "", // checked below: both literals gone
		"omicron alicex xalice":       "omicron alicex xalice",
		"Alice is a different case":   "Alice is a different case",
		"/srv/_bob_minecraft BOB Bob": "/srv/_friend_minecraft friend friend",
		"mount /tank_main/data":       "mount /pool_a/data",
	}
	for in, want := range cases {
		got := s.Text(in)
		if want == "" {
			if strings.Contains(got, "alice") || strings.Contains(got, "box-alpha") {
				t.Errorf("Text(%q) = %q, literals survived", in, got)
			}
			continue
		}
		if got != want {
			t.Errorf("Text(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLongestLiteralFirst(t *testing.T) {
	s, err := scrub.New(scrub.Config{Literals: []scrub.Literal{
		{Find: "micro", Replace: "short"},
		{Find: "micro-calc", Replace: "long"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Text("node micro-calc and micro"); got != "node long and short" {
		t.Errorf("Text = %q, want %q", got, "node long and short")
	}
}

func isDocIPv4(s string) bool {
	a, err := netip.ParseAddr(s)
	if err != nil || !a.Is4() {
		return false
	}
	for _, p := range []string{"192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"} {
		if netip.MustParsePrefix(p).Contains(a) {
			return true
		}
	}
	return false
}

var dottedQuad = regexp.MustCompile(`\d+\.\d+\.\d+\.\d+`)

func TestIPv4(t *testing.T) {
	s := newScrubber(t)
	got := s.Text("inet 192.168.1.153/24 brd 192.168.1.255 peer 192.168.1.153:22")
	quads := dottedQuad.FindAllString(got, -1)
	if len(quads) != 3 {
		t.Fatalf("Text = %q, want 3 addresses", got)
	}
	for _, q := range quads {
		if !isDocIPv4(q) {
			t.Errorf("placeholder %q is not in a documentation range", q)
		}
	}
	if quads[0] != quads[2] {
		t.Errorf("same address got different placeholders: %q", got)
	}
	if quads[0] == quads[1] {
		t.Errorf("different addresses share a placeholder: %q", got)
	}
	if !strings.Contains(got, "/24") || !strings.HasSuffix(got, ":22") {
		t.Errorf("prefix or port suffix lost: %q", got)
	}
}

func TestIPv4Kept(t *testing.T) {
	s := newScrubber(t)
	for _, in := range []string{
		"0.0.0.0:8443->80/tcp", "127.0.0.1", "127.8.9.1", "255.255.255.255",
		"192.0.2.7", "198.51.100.3", "203.0.113.9",
		"zfs-utils 2.4.0.1-1", "pkg 1.2.3.4-2", "v1.2.3.4", "1.2.3.4.5", "x1.2.3.4", "1.2.3.4_x",
		"256.1.1.1", "999.999.999.999",
	} {
		if got := s.Text(in); got != in {
			t.Errorf("Text(%q) = %q, want unchanged", in, got)
		}
	}
}

func TestIPv4PlaceholdersStayInDocRangesPastOneBlock(t *testing.T) {
	s := newScrubber(t)
	seen := map[string]bool{}
	for i := 0; i < 600; i++ {
		in := netip.AddrFrom4([4]byte{10, 1, byte(i / 256), byte(i % 256)}).String()
		got := s.Text(in)
		if seen[got] {
			t.Fatalf("placeholder %q reused for a different address", got)
		}
		seen[got] = true
		if !isDocIPv4(got) {
			t.Fatalf("address %d -> %q, not a documentation address", i, got)
		}
	}
}

func TestIPv6(t *testing.T) {
	s := newScrubber(t)
	in := `"local":"fe80::ec0d:9aff:feb0:a7f1%ibp17s0" pub 2a01:4f8:c0c:1234::1 again fe80::ec0d:9aff:feb0:a7f1`
	got := s.Text(in)
	if strings.Contains(got, "fe80") || strings.Contains(got, "2a01") {
		t.Fatalf("Text = %q, IPv6 survived", got)
	}
	if !strings.Contains(got, "%ibp17s0") {
		t.Errorf("zone suffix lost: %q", got)
	}
	re := regexp.MustCompile(`2001:db8::[0-9a-f]+`)
	ph := re.FindAllString(got, -1)
	if len(ph) != 3 || ph[0] != ph[2] || ph[0] == ph[1] {
		t.Errorf("placeholders %v from %q: want 3, first == third, first != second", ph, got)
	}
}

func TestIPv6Kept(t *testing.T) {
	s := newScrubber(t)
	for _, in := range []string{"[::]:8443->80/tcp", "::1", "2001:db8::5", "17:29:07.989443", "E1104 17:29:07", "a:b", "1:2.40.1-1", "std::vector<int>", "ns::fd::read", "x_fe80::1"} {
		if got := s.Text(in); got != in {
			t.Errorf("Text(%q) = %q, want unchanged", in, got)
		}
	}
}

func TestHardwareAddresses(t *testing.T) {
	s := newScrubber(t)
	mac := "link/ether 3c:4a:92:f0:11:2b brd ff:ff:ff:ff:ff:ff"
	ib := "80:00:02:08:fe:80:00:00:00:00:00:00:ec:0d:9a:03:00:b0:a7:f1"
	serial := "Device Serial Number ec-0d-9a-03-00-b0-a7-f0"

	pairs := regexp.MustCompile(`[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5,}`)
	for _, in := range []string{mac, ib, serial} {
		got := s.Text(in)
		orig := pairs.FindAllString(in, -1)
		repl := pairs.FindAllString(got, -1)
		if len(orig) != len(repl) {
			t.Fatalf("Text(%q) = %q: %d addresses became %d", in, got, len(orig), len(repl))
		}
		for i := range orig {
			if orig[i] == repl[i] {
				t.Errorf("address %q not replaced", orig[i])
			}
			if len(orig[i]) != len(repl[i]) {
				t.Errorf("%q -> %q: pair count or separator changed", orig[i], repl[i])
			}
			if !strings.HasPrefix(repl[i], "02") {
				t.Errorf("placeholder %q does not start with 02", repl[i])
			}
			sep := orig[i][2]
			if repl[i][2] != sep {
				t.Errorf("%q -> %q: separator changed", orig[i], repl[i])
			}
		}
	}
	if a, b := s.Text("3c:4a:92:f0:11:2b"), s.Text("x 3c:4a:92:f0:11:2b"); "x "+a != b {
		t.Errorf("same MAC got different placeholders: %q vs %q", a, b)
	}
}

func TestHardwareAddressesKept(t *testing.T) {
	s := newScrubber(t)
	for _, in := range []string{"12:34:56", "2026-11-04", "ab:cd:ef:01:23"} {
		if got := s.Text(in); got != in {
			t.Errorf("Text(%q) = %q, want unchanged", in, got)
		}
	}
}

func TestHex64(t *testing.T) {
	s := newScrubber(t)
	got := s.Text("Port GUID: 0xec0d9a0300b0a7f1 node 0xEC0D9A0300B0A7F0 small 0x1f")
	re := regexp.MustCompile(`0x[0-9a-fA-F]{16}`)
	for _, h := range re.FindAllString(got, -1) {
		if !strings.HasPrefix(h, "0x02000000") {
			t.Errorf("64-bit id %q not replaced", h)
		}
	}
	if !strings.Contains(got, "small 0x1f") {
		t.Errorf("short hex changed: %q", got)
	}
}

func TestUUID(t *testing.T) {
	s := newScrubber(t)
	got := s.Text("UUID=3f2b6c1e-9a4d-4e2b-8c7a-1d2e3f4a5b6c")
	if !regexp.MustCompile(`^UUID=00000000-0000-4000-8000-[0-9a-f]{12}$`).MatchString(got) {
		t.Errorf("Text = %q", got)
	}
}

func TestEmail(t *testing.T) {
	s := newScrubber(t)
	got := s.Text("maintainer someone.else+x@gmail.com and dev@kernel.example.co.uk")
	if strings.Contains(got, "gmail") || strings.Contains(got, "kernel.example") {
		t.Fatalf("Text = %q, email survived", got)
	}
	if strings.Count(got, "@example.invalid") != 2 {
		t.Errorf("Text = %q, want two @example.invalid placeholders", got)
	}
	for _, unit := range []string{"getty@tty1.service", "user@1000.service", "systemd-fsck@dev-sda1.service", "container@x.scope", "a@b.socket", "serial-getty@ttyS0.target"} {
		if got := s.Text(unit); got != unit {
			t.Errorf("Text(%q) = %q, unit name changed", unit, got)
		}
	}
}

// A sample shaped like real fixture output, with one of everything.
const sample = `Linux box-alpha 7.2.14-arch1-1
/home/alice/compose/_bob_minecraft/data on /tank_main/nextcloud
inet 192.168.1.153/24 brd 192.168.1.255 and 10.244.0.7 and 169.254.95.120
inet6 fe80::ec0d:9aff:feb0:a7f1%eno25 and 2a01:4f8::1
link/ether 3c:4a:92:f0:11:2b ib 80:00:02:08:fe:80:00:00:00:00:00:00:ec:0d:9a:03:00:b0:a7:f1
Port GUID: 0xec0d9a0300b0a7f1 UUID=3f2b6c1e-9a4d-4e2b-8c7a-1d2e3f4a5b6c
mail alice.surname@gmail.com target alice@192.168.1.153
keep: zfs-utils 2.4.0-1 getty@tty1.service 0.0.0.0:8443 [::]:8443 127.0.0.1 17:29:07.98`

func TestTextIsIdempotent(t *testing.T) {
	s := newScrubber(t)
	once := s.Text(sample)
	if twice := s.Text(once); twice != once {
		t.Errorf("Text not idempotent:\nonce:  %q\ntwice: %q", once, twice)
	}
}

func TestLeaks(t *testing.T) {
	s := newScrubber(t)
	if leaks := s.Leaks(sample); len(leaks) == 0 {
		t.Fatal("Leaks(raw sample) is empty, want findings")
	}
	clean := s.Text(sample)
	if leaks := s.Leaks(clean); len(leaks) != 0 {
		t.Errorf("Leaks(Text(sample)) = %v, want none", leaks)
	}
	for _, kept := range []string{"zfs-utils 2.4.0-1", "getty@tty1.service", "0.0.0.0:8443", "[::]:8443", "127.0.0.1"} {
		if leaks := s.Leaks(kept); len(leaks) != 0 {
			t.Errorf("Leaks(%q) = %v, want none", kept, leaks)
		}
	}
}

func TestLeaksFindsEachKind(t *testing.T) {
	s := newScrubber(t)
	for _, in := range []string{"box-alpha", "192.168.1.1", "fe80::1", "3c:4a:92:f0:11:2b", "0xec0d9a0300b0a7f1",
		"3f2b6c1e-9a4d-4e2b-8c7a-1d2e3f4a5b6c", "x@gmail.com"} {
		if leaks := s.Leaks(in); len(leaks) == 0 {
			t.Errorf("Leaks(%q) is empty", in)
		}
	}
}

func TestDeterministicAcrossScrubbers(t *testing.T) {
	a, b := newScrubber(t), newScrubber(t)
	if a.Text(sample) != b.Text(sample) {
		t.Error("two Scrubbers given the same input produced different output")
	}
}

func TestCounts(t *testing.T) {
	s := newScrubber(t)
	if c := s.Counts(); len(c) != 0 {
		t.Errorf("Counts before any Text = %v, want empty", c)
	}
	s.Text(sample)
	c := s.Counts()
	for _, kind := range []string{"literal", "hwaddr", "hex64", "uuid", "email", "ipv6", "ipv4"} {
		if c[kind] == 0 {
			t.Errorf("Counts()[%q] = 0 after scrubbing the sample; counts = %v", kind, c)
		}
	}
	// Distinct values: the sample has 2 distinct IPv6 addresses.
	if c["ipv6"] != 2 {
		t.Errorf("Counts()[ipv6] = %d, want 2", c["ipv6"])
	}
	for kind, n := range c {
		if n <= 0 {
			t.Errorf("Counts()[%q] = %d, absent kinds must be left out", kind, n)
		}
	}
}
