package scrub

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	reQueryLine   = regexp.MustCompile(`^(\S+) (\S+)$`)
	reUpgradeLine = regexp.MustCompile(`^(\S+) (\S+) -> (\S+)$`)
	reDigits      = regexp.MustCompile(`[0-9]+`)
)

// Versions returns text with fake package versions when id is one of the
// FakeVersions IDs, and text unchanged otherwise.
//
// It rewrites lines in the two formats pacman and paru print:
// "name version" (pacman -Q) and "name old -> new" (paru -Qua). About two
// thirds of package names get fake versions, chosen by a keyed hash of the
// name (keyed with FakeVersions.Secret), so the choice is the same on every
// run but cannot be worked out without the secret. Names in Keep are never
// changed.
//
// A fake version has the same shape as the real one: the epoch ("1:") and the
// release after the last '-' are kept, and every run of digits in between is
// replaced by another number with the same count of digits, so it still parses
// as a version. The fake depends only on the secret, the package name and
// the real version, so the same package shows the same fake version in every
// fixture, and a different secret gives different fakes. Packages get
// unrelated fakes even when their real versions are equal, so knowing one
// package's real and fake version reveals nothing about any other.
// Lines in any other format are left alone.
func (s *Scrubber) Versions(id, text string) string {
	if !s.fakeIDs[id] {
		return text
	}
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if m := reUpgradeLine.FindStringSubmatch(line); m != nil {
			lines[i] = m[1] + " " + s.fakeVersion(m[1], m[2]) + " -> " + s.fakeVersion(m[1], m[3])
		} else if m := reQueryLine.FindStringSubmatch(line); m != nil {
			lines[i] = m[1] + " " + s.fakeVersion(m[1], m[2])
		}
	}
	return strings.Join(lines, "\n")
}

func (s *Scrubber) fakeVersion(name, version string) string {
	if s.keepVersions[name] || s.keyed("pick\x00"+name)%3 == 0 {
		return version
	}
	epoch, rest := "", version
	if i := strings.IndexByte(rest, ':'); i >= 0 {
		epoch, rest = rest[:i+1], rest[i+1:]
	}
	release := ""
	if j := strings.LastIndexByte(rest, '-'); j >= 0 {
		rest, release = rest[:j], rest[j:]
	}
	run := 0
	rest = reDigits.ReplaceAllStringFunc(rest, func(d string) string {
		run++
		return otherNumber(d, s.keyed(fmt.Sprintf("value\x00%s\x00%s\x00%d", name, version, run)))
	})
	return epoch + rest + release
}

// otherNumber returns a different number with the same count of digits as d.
// Only the last 9 digits change, which keeps the arithmetic in range.
func otherNumber(d string, seed uint64) string {
	head, tail := "", d
	if len(d) > 9 {
		head, tail = d[:len(d)-9], d[len(d)-9:]
	}
	mod := uint64(1)
	for range len(tail) {
		mod *= 10
	}
	n, _ := strconv.ParseUint(tail, 10, 64)
	// Adding 1..mod-1 modulo mod always lands on a different value.
	n = (n + 1 + seed%(mod-1)) % mod
	return head + fmt.Sprintf("%0*d", len(tail), n)
}

// keyed is HMAC-SHA256 of msg under the FakeVersions secret, as a number.
func (s *Scrubber) keyed(msg string) uint64 {
	m := hmac.New(sha256.New, s.versionSecret)
	m.Write([]byte(msg))
	return binary.BigEndian.Uint64(m.Sum(nil))
}
