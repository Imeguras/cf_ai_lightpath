// Package scrub removes identifying data from inventory fixtures so they can
// be published (phase 2 of the plan).
//
// Two kinds of rules apply. Literals are exact strings from a private config
// file (hostnames, user names, pool names, people's names); the config is
// never published because it lists the very values it hides. Patterns catch
// data no list can enumerate: IP addresses, hardware addresses, 64-bit IDs,
// UUIDs and email addresses.
//
// Every replaced value gets a stable placeholder: the same input value always
// maps to the same placeholder within one Scrubber, so relations between
// fixtures survive (an address seen in ip-addr and in the journal stays the
// same address). Placeholders are numbered in order of first appearance, so
// the same inputs in the same order always give the same output.
package scrub

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

// Literal replaces one exact string.
type Literal struct {
	Find    string `json:"find"`
	Replace string `json:"replace"`
	// IgnoreCase makes Find match regardless of case. By default matching is
	// case-sensitive, so "micron" does not touch a vendor name like "Micron".
	IgnoreCase bool `json:"ignore_case,omitempty"`
}

// Config is the private scrub configuration.
type Config struct {
	Literals []Literal `json:"literals"`
	// Drop lists fixture IDs that are never published.
	Drop []string `json:"drop,omitempty"`
	// FakeVersions hides most installed package versions (see Versions).
	FakeVersions FakeVersions `json:"fake_versions,omitempty"`
}

// FakeVersions says which fixtures list packages and which packages must
// keep their real version (for example the ones a diagnosis depends on).
type FakeVersions struct {
	IDs  []string `json:"ids,omitempty"`
	Keep []string `json:"keep,omitempty"`
	// Secret keys both which packages are faked and the fake values. This
	// code is public, so without a secret anyone could recompute the fakes
	// for guessed versions and tell real from fake. Required when IDs is set.
	Secret string `json:"secret,omitempty"`
}

// LoadConfig reads a Config from a JSON file. Unknown fields are an error, so
// a typo cannot silently disable a rule.
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var cfg Config
	if err := dec.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, nil
}

// Scrubber applies a Config and remembers the placeholders it handed out.
type Scrubber struct {
	literals []literal
	drop     map[string]bool
	// fakeIDs and keepVersions come from Config.FakeVersions.
	fakeIDs, keepVersions map[string]bool
	versionSecret         []byte
	// seen maps kind -> original value -> placeholder.
	seen map[string]map[string]string
}

type literal struct {
	re            *regexp.Regexp
	find, replace string
}

// New checks cfg and returns a Scrubber. It returns an error if a literal has
// an empty Find or Replace, or if any Replace contains any Find (compared
// case-insensitively), since that would make scrubbing non-idempotent. It
// also returns an error if FakeVersions lists IDs but has no Secret.
func New(cfg Config) (*Scrubber, error) {
	lits := make([]literal, 0, len(cfg.Literals))
	for i, l := range cfg.Literals {
		if l.Find == "" || l.Replace == "" {
			return nil, fmt.Errorf("literal %d: find and replace must both be set", i)
		}
		for _, other := range cfg.Literals {
			if other.Find != "" && strings.Contains(strings.ToLower(l.Replace), strings.ToLower(other.Find)) {
				return nil, fmt.Errorf("literal %d: replacement %q contains %q", i, l.Replace, other.Find)
			}
		}
		pat := regexp.QuoteMeta(l.Find)
		if l.IgnoreCase {
			pat = "(?i)" + pat
		}
		lits = append(lits, literal{re: regexp.MustCompile(pat), find: l.Find, replace: l.Replace})
	}
	if len(cfg.FakeVersions.IDs) > 0 && cfg.FakeVersions.Secret == "" {
		return nil, fmt.Errorf("fake_versions lists ids but has no secret")
	}
	// Longest Find first, so "host-long" is replaced before "host".
	sort.SliceStable(lits, func(a, b int) bool { return len(lits[a].find) > len(lits[b].find) })
	drop := make(map[string]bool, len(cfg.Drop))
	for _, id := range cfg.Drop {
		drop[id] = true
	}
	return &Scrubber{
		literals: lits, drop: drop, seen: map[string]map[string]string{},
		fakeIDs: set(cfg.FakeVersions.IDs), keepVersions: set(cfg.FakeVersions.Keep),
		versionSecret: []byte(cfg.FakeVersions.Secret),
	}, nil
}

func set(items []string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, it := range items {
		m[it] = true
	}
	return m
}

// Text returns in with identifying data replaced, in this order:
//
//  1. Literals, longest Find first, where the match is not directly preceded
//     or followed by an ASCII letter or digit ("/home/micron/" and
//     "_micron_" match, "omicron" does not).
//  2. Hardware addresses: runs of six or more hex pairs separated by ':' or
//     by '-' (MACs, 20-byte InfiniBand addresses, PCIe serial numbers). The
//     placeholder keeps the separator and the number of pairs, starts with
//     02 and is otherwise zero apart from a counter in the last pairs.
//  3. 64-bit hex IDs written as 0x followed by exactly 16 hex digits
//     (InfiniBand GUIDs, kernel addresses) become 0x02000000 followed by an
//     8-digit counter.
//  4. UUIDs become 00000000-0000-4000-8000- followed by a 12-digit counter.
//  5. Email addresses become userN@example.invalid. Systemd unit names such
//     as getty@tty1.service or user@1000.service are not email addresses.
//  6. IPv6 addresses become 2001:db8::N, keeping any %zone suffix. "::",
//     "::1" and addresses already in 2001:db8::/32 are kept.
//     An address counts only when it is not glued to a letter, digit,
//     '.', ':' or '_', so names like std::vector are left alone.
//  7. IPv4 addresses become addresses in the documentation ranges
//     (192.0.2.N, then 198.51.100.N, then 203.0.113.N; once those 762 run
//     out, the placeholder is the text ipv4-N, which is no address). 0.0.0.0,
//     255.255.255.255, 127.0.0.0/8 and the documentation ranges are kept. A
//     dotted quad counts only when it is not preceded by a letter, digit or
//     '.', and not followed by a letter, digit, '.', '-' or '_', so package
//     versions like 1.2.3.4-1 are left alone.
//
// Text is idempotent: Text(Text(s)) == Text(s).
func (s *Scrubber) Text(in string) string {
	out := in
	for _, l := range s.literals {
		out = replaceBounded(out, l.re, isAlnum, isAlnum, func(m string) (string, bool) {
			s.note("literal", m, l.replace)
			return l.replace, true
		})
	}
	for _, p := range s.patterns() {
		out = p.apply(out)
	}
	return out
}

// Leaks lists what Text would still replace in in: any literal or pattern
// match that is not already a placeholder or a kept value. An empty result
// means in is clean.
func (s *Scrubber) Leaks(in string) []string {
	var leaks []string
	for _, l := range s.literals {
		replaceBounded(in, l.re, isAlnum, isAlnum, func(m string) (string, bool) {
			leaks = append(leaks, "literal: "+m)
			return m, false
		})
	}
	for _, p := range s.patterns() {
		p.scan(in, func(m string) { leaks = append(leaks, p.kind+": "+m) })
	}
	return leaks
}

// Counts reports how many distinct values were replaced so far, by kind:
// "literal", "hwaddr", "hex64", "uuid", "email", "ipv6" and "ipv4". Kinds
// with no replacements are absent.
func (s *Scrubber) Counts() map[string]int {
	counts := map[string]int{}
	for kind, m := range s.seen {
		if len(m) > 0 {
			counts[kind] = len(m)
		}
	}
	return counts
}
