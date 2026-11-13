// Package events turns systemd journal entries (journalctl --output=json)
// into the few kinds of events Lightpath reacts to: systemd unit state
// changes, kernel warnings and link changes, and package transactions
// (reported to the journal by Lightpath's ALPM hooks).
package events

import (
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Kind is what an event is about.
type Kind string

const (
	Unit    Kind = "unit"
	Kernel  Kind = "kernel"
	Package Kind = "package"
)

// Event is one thing that happened on the server.
type Event struct {
	Time time.Time `json:"time"`
	Kind Kind      `json:"kind"`
	// Subject: the unit ("kubelet.service"), the package ("linux"), or for
	// the kernel the network interface of a link change and "kernel"
	// otherwise.
	Subject string `json:"subject"`
	// Change: unit "started", "stopped", "failed" or "restarting"; kernel
	// "warning", "error", "link-up" or "link-down"; package "installed",
	// "upgraded" or "removed".
	Change  string `json:"change"`
	Message string `json:"message"`
	// Repeats: how many identical events (same Kind, Subject and Change)
	// were left out since the previous one was recorded (see daemon).
	Repeats int `json:"repeats,omitempty"`
}

// Entry is one parsed journal entry: always its cursor and time, plus the
// event when it is one we react to.
type Entry struct {
	Cursor string
	Time   time.Time
	Event  *Event
}

// UnitMessages maps systemd's catalog MESSAGE_IDs to unit changes.
var UnitMessages = map[string]string{
	"39f53479d3a045ac8e11786248231fbf": "started",
	"9d1aaa27d60140bd96365438aad20286": "stopped",
	"7ad2d189f7e94e70a38c781354912448": "stopped", // deactivated successfully
	"d9b373ed55a64feb8242e02dbe79a49c": "failed",
	"be02cf6855d2428ba40df7e9d022f03d": "failed", // job failed (older systemd)
	"5eb03494b6584870a536b337290809b3": "restarting",
}

// HookTags maps the SYSLOG_IDENTIFIERs the ALPM hooks log with
// (deploy/arch/*.hook, via systemd-cat) to package changes. Each such entry's
// MESSAGE is one package name.
var HookTags = map[string]string{
	"lightpath-alpm-install": "installed",
	"lightpath-alpm-upgrade": "upgraded",
	"lightpath-alpm-remove":  "removed",
}

// ErrMalformed is returned for a line that is not a journal JSON entry
// with __CURSOR and a numeric __REALTIME_TIMESTAMP.
var ErrMalformed = errors.New("not a journal entry")

// Parse reads one line of `journalctl --output=json`. Field values are
// strings; MESSAGE may instead be a JSON array of bytes (the journal's form
// for non-UTF-8 text) and is decoded. Time comes from
// __REALTIME_TIMESTAMP (microseconds since the epoch, UTC).
//
// The entry carries an event when:
//   - SYSLOG_IDENTIFIER is "systemd", UNIT is set and is a .service,
//     .socket, .timer, .path or .target unit (transient .mount, .scope,
//     .slice and .device units are noise), and MESSAGE_ID is in
//     UnitMessages: a Unit event for UNIT;
//   - _TRANSPORT is "kernel" and MESSAGE contains "<iface> NIC Link is Up"
//     or "... Down" (any priority): a Kernel "link-up"/"link-down" event for
//     that interface;
//   - otherwise _TRANSPORT is "kernel" with PRIORITY 0-3 ("error") or 4
//     ("warning"): a Kernel event for "kernel";
//   - SYSLOG_IDENTIFIER is in HookTags and MESSAGE is not blank: a Package
//     event for the trimmed MESSAGE.
//
// Message is MESSAGE, trimmed. Other entries have a nil Event.
func Parse(line []byte) (Entry, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(line, &raw); err != nil {
		return Entry{}, ErrMalformed
	}
	field := func(name string) string { return text(raw[name]) }

	cursor := field("__CURSOR")
	micros, err := strconv.ParseInt(field("__REALTIME_TIMESTAMP"), 10, 64)
	if cursor == "" || err != nil {
		return Entry{}, ErrMalformed
	}
	entry := Entry{Cursor: cursor, Time: time.UnixMicro(micros).UTC()}
	message := strings.TrimSpace(field("MESSAGE"))
	event := func(kind Kind, subject, change string) (Entry, error) {
		entry.Event = &Event{Time: entry.Time, Kind: kind, Subject: subject, Change: change, Message: message}
		return entry, nil
	}

	ident := field("SYSLOG_IDENTIFIER")
	switch {
	case ident == "systemd" && unitRE.MatchString(field("UNIT")):
		if change, ok := UnitMessages[field("MESSAGE_ID")]; ok {
			return event(Unit, field("UNIT"), change)
		}
	case field("_TRANSPORT") == "kernel":
		if m := linkRE.FindStringSubmatch(message); m != nil {
			return event(Kernel, m[1], "link-"+strings.ToLower(m[2]))
		}
		switch field("PRIORITY") {
		case "0", "1", "2", "3":
			return event(Kernel, "kernel", "error")
		case "4":
			return event(Kernel, "kernel", "warning")
		}
	case HookTags[ident] != "" && message != "":
		return event(Package, message, HookTags[ident])
	}
	return entry, nil
}

var unitRE = regexp.MustCompile(`\.(service|socket|timer|path|target)$`)

var linkRE = regexp.MustCompile(`(\S+?):? NIC Link is (Up|Down)`)

// text decodes a journal field: a JSON string, or a JSON array of bytes.
func text(v json.RawMessage) string {
	var s string
	if json.Unmarshal(v, &s) == nil {
		return s
	}
	var b []byte
	var ints []int
	if json.Unmarshal(v, &ints) == nil {
		b = make([]byte, len(ints))
		for i, n := range ints {
			b[i] = byte(n)
		}
		return strings.ToValidUTF8(string(b), "\uFFFD")
	}
	return ""
}
