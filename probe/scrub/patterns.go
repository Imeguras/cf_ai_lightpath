package scrub

import (
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

// pattern is one built-in detector. A regexp finds candidates; the boundary
// checks reject candidates glued to neighbouring text; valid decides whether
// the candidate really is such a value; keep spares placeholders and values
// that are safe to publish; make builds the placeholder for the n-th distinct
// value (n starts at 1).
type pattern struct {
	kind                string
	re                  *regexp.Regexp
	badBefore, badAfter func(byte) bool
	valid               func(string) bool
	keep                func(string) bool
	key                 func(string) string
	make                func(n int, m string) string
	s                   *Scrubber
}

func (p pattern) apply(in string) string {
	return replaceBounded(in, p.re, p.badBefore, p.badAfter, func(m string) (string, bool) {
		if !p.valid(m) || p.keep(m) {
			return m, false
		}
		seen := p.s.seenKind(p.kind)
		k := p.key(m)
		if ph, ok := seen[k]; ok {
			return ph, true
		}
		ph := p.make(len(seen)+1, m)
		seen[k] = ph
		return ph, true
	})
}

func (p pattern) scan(in string, report func(string)) {
	replaceBounded(in, p.re, p.badBefore, p.badAfter, func(m string) (string, bool) {
		if p.valid(m) && !p.keep(m) {
			report(m)
		}
		return m, false
	})
}

// replaceBounded calls f for every match of re that is not directly preceded
// by a byte rejected by badBefore or followed by one rejected by badAfter, and
// splices in f's result when f reports a change.
func replaceBounded(s string, re *regexp.Regexp, badBefore, badAfter func(byte) bool, f func(string) (string, bool)) string {
	var b strings.Builder
	last := 0
	for _, loc := range re.FindAllStringIndex(s, -1) {
		start, end := loc[0], loc[1]
		if start > 0 && badBefore(s[start-1]) || end < len(s) && badAfter(s[end]) {
			continue
		}
		repl, changed := f(s[start:end])
		if !changed {
			continue
		}
		b.WriteString(s[last:start])
		b.WriteString(repl)
		last = end
	}
	if last == 0 {
		return s
	}
	b.WriteString(s[last:])
	return b.String()
}

func (s *Scrubber) seenKind(kind string) map[string]string {
	m, ok := s.seen[kind]
	if !ok {
		m = map[string]string{}
		s.seen[kind] = m
	}
	return m
}

func (s *Scrubber) note(kind, orig, placeholder string) {
	s.seenKind(kind)[orig] = placeholder
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isHex(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func anyOf(set string, fs ...func(byte) bool) func(byte) bool {
	return func(c byte) bool {
		for _, f := range fs {
			if f(c) {
				return true
			}
		}
		return strings.IndexByte(set, c) >= 0
	}
}

func always(string) bool { return true }

var (
	reHWColon  = regexp.MustCompile(`(?i)[0-9a-f]{2}(?::[0-9a-f]{2}){5,}`)
	reHWHyphen = regexp.MustCompile(`(?i)[0-9a-f]{2}(?:-[0-9a-f]{2}){5,}`)
	reHex64    = regexp.MustCompile(`0[xX][0-9a-fA-F]{16}`)
	reUUID     = regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	reEmail    = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}`)
	reIPv6     = regexp.MustCompile(`(?i)(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}`)
	reIPv4     = regexp.MustCompile(`\d{1,3}(?:\.\d{1,3}){3}`)

	docIPv4 = []netip.Prefix{
		netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("198.51.100.0/24"),
		netip.MustParsePrefix("203.0.113.0/24"),
	}
	docIPv6 = netip.MustParsePrefix("2001:db8::/32")

	unitSuffixes = map[string]bool{
		"service": true, "socket": true, "target": true, "mount": true, "automount": true, "swap": true,
		"timer": true, "path": true, "slice": true, "scope": true, "device": true,
	}
)

// patterns returns the built-in detectors in the order Text applies them.
func (s *Scrubber) patterns() []pattern {
	hw := func(sep byte, re *regexp.Regexp) pattern {
		edge := anyOf(string(sep), isHex)
		return pattern{kind: "hwaddr", re: re, badBefore: edge, badAfter: edge, valid: always,
			keep: func(m string) bool { return isHWPlaceholder(m, sep) }, key: lower,
			make: func(n int, m string) string { return hwPlaceholder(n, strings.Count(m, string(sep))+1, sep) }, s: s}
	}
	ipEdge := anyOf(":._", isAlnum)
	return []pattern{
		hw(':', reHWColon),
		hw('-', reHWHyphen),
		{kind: "hex64", re: reHex64, badBefore: isAlnum, badAfter: isAlnum, valid: always,
			keep: func(m string) bool { return strings.HasPrefix(lower(m), "0x02000000") }, key: lower,
			make: func(n int, _ string) string { return fmt.Sprintf("0x02000000%08x", n) }, s: s},
		{kind: "uuid", re: reUUID, badBefore: anyOf("-", isHex), badAfter: anyOf("-", isHex), valid: always,
			keep: func(m string) bool { return strings.HasPrefix(lower(m), "00000000-0000-4000-8000-") }, key: lower,
			make: func(n int, _ string) string { return fmt.Sprintf("00000000-0000-4000-8000-%012x", n) }, s: s},
		{kind: "email", re: reEmail, badBefore: func(byte) bool { return false }, badAfter: anyOf("-", isAlnum),
			valid: func(m string) bool { return !unitSuffixes[lower(m[strings.LastIndexByte(m, '.')+1:])] },
			keep:  func(m string) bool { return strings.HasSuffix(lower(m), "@example.invalid") }, key: lower,
			make: func(n int, _ string) string { return fmt.Sprintf("user%d@example.invalid", n) }, s: s},
		{kind: "ipv6", re: reIPv6, badBefore: ipEdge, badAfter: ipEdge,
			valid: func(m string) bool { a, err := netip.ParseAddr(m); return err == nil && a.Is6() && !a.Is4In6() },
			keep: func(m string) bool {
				a := netip.MustParseAddr(m)
				return a.IsUnspecified() || a.IsLoopback() || docIPv6.Contains(a)
			},
			key:  func(m string) string { return netip.MustParseAddr(m).String() },
			make: func(n int, _ string) string { return fmt.Sprintf("2001:db8::%x", n) }, s: s},
		{kind: "ipv4", re: reIPv4, badBefore: anyOf(".", isAlnum), badAfter: anyOf(".-_", isAlnum),
			valid: func(m string) bool { a, err := netip.ParseAddr(m); return err == nil && a.Is4() },
			keep:  keepIPv4, key: func(m string) string { return m }, make: ipv4Placeholder, s: s},
	}
}

func keepIPv4(m string) bool {
	a := netip.MustParseAddr(m)
	if a.IsUnspecified() || a.IsLoopback() || a == netip.AddrFrom4([4]byte{255, 255, 255, 255}) {
		return true
	}
	for _, p := range docIPv4 {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func ipv4Placeholder(n int, _ string) string {
	for _, p := range docIPv4 {
		if n <= 254 {
			b := p.Addr().As4()
			b[3] = byte(n)
			return netip.AddrFrom4(b).String()
		}
		n -= 254
	}
	return fmt.Sprintf("ipv4-%d", n+3*254)
}

// hwPlaceholder builds "02" followed by zero pairs and a 24-bit counter in
// the last three pairs, with pairs pairs in total.
func hwPlaceholder(n, pairs int, sep byte) string {
	parts := make([]string, pairs)
	parts[0] = "02"
	for i := 1; i < pairs; i++ {
		parts[i] = "00"
	}
	for i := 0; i < 3 && pairs-1-i > 0; i++ {
		parts[pairs-1-i] = fmt.Sprintf("%02x", (n>>(8*i))&0xff)
	}
	return strings.Join(parts, string(sep))
}

func isHWPlaceholder(m string, sep byte) bool {
	parts := strings.Split(lower(m), string(sep))
	if len(parts) < 6 || parts[0] != "02" {
		return false
	}
	for _, p := range parts[1 : len(parts)-3] {
		if p != "00" {
			return false
		}
	}
	return true
}

func lower(s string) string { return strings.ToLower(s) }
