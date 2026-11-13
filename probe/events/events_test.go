package events_test

import (
	"errors"
	"testing"
	"time"

	"lightpath/probe/events"
)

// Shapes copied from the server's journal (cursors shortened).
const (
	started  = `{"__CURSOR":"s=1;i=a","__REALTIME_TIMESTAMP":"1794166897613892","SYSLOG_IDENTIFIER":"systemd","UNIT":"kubelet.service","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","PRIORITY":"6","MESSAGE":"Started The Kubernetes Node Agent.","_TRANSPORT":"journal"}`
	exited   = `{"__CURSOR":"s=1;i=b","__REALTIME_TIMESTAMP":"1794166897782674","SYSLOG_IDENTIFIER":"systemd","UNIT":"kubelet.service","MESSAGE_ID":"98e322203f7a4ed290d09fe03c09fe15","PRIORITY":"5","MESSAGE":"kubelet.service: Main process exited, code=exited, status=1/FAILURE","_TRANSPORT":"journal"}`
	failed   = `{"__CURSOR":"s=1;i=c","__REALTIME_TIMESTAMP":"1794166897782823","SYSLOG_IDENTIFIER":"systemd","UNIT":"kubelet.service","MESSAGE_ID":"d9b373ed55a64feb8242e02dbe79a49c","PRIORITY":"4","MESSAGE":"kubelet.service: Failed with result 'exit-code'.","_TRANSPORT":"journal"}`
	linkUp   = `{"__CURSOR":"s=1;i=d","__REALTIME_TIMESTAMP":"1794151429841620","SYSLOG_IDENTIFIER":"kernel","PRIORITY":"6","MESSAGE":"igb 0000:01:00.1 eno25: igb: eno25 NIC Link is Up 100 Mbps Full Duplex, Flow Control: RX/TX","_TRANSPORT":"kernel"}`
	warning  = `{"__CURSOR":"s=1;i=e","__REALTIME_TIMESTAMP":"1794162996630751","SYSLOG_IDENTIFIER":"kernel","PRIORITY":"4","MESSAGE":"zfs: module license taints kernel.","_TRANSPORT":"kernel"}`
	upgraded = `{"__CURSOR":"s=1;i=f","__REALTIME_TIMESTAMP":"1794166900000000","SYSLOG_IDENTIFIER":"lightpath-alpm-upgrade","PRIORITY":"6","MESSAGE":"linux\n","_TRANSPORT":"stdout"}`
)

func us(n int64) time.Time { return time.UnixMicro(n).UTC() }

func parse(t *testing.T, line string) events.Entry {
	t.Helper()
	e, err := events.Parse([]byte(line))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return e
}

func want(t *testing.T, got events.Entry, w events.Event) {
	t.Helper()
	if got.Event == nil {
		t.Fatalf("no event, want %+v", w)
	}
	if *got.Event != w {
		t.Fatalf("event = %+v, want %+v", *got.Event, w)
	}
}

func TestUnitEvents(t *testing.T) {
	want(t, parse(t, started), events.Event{Time: us(1794166897613892), Kind: events.Unit, Subject: "kubelet.service", Change: "started", Message: "Started The Kubernetes Node Agent."})
	want(t, parse(t, failed), events.Event{Time: us(1794166897782823), Kind: events.Unit, Subject: "kubelet.service", Change: "failed", Message: "kubelet.service: Failed with result 'exit-code'."})
}

func TestUnitTypesThatCount(t *testing.T) {
	for _, unit := range []string{"a.service", "b.socket", "c.timer", "d.path", "e.target"} {
		line := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"1","SYSLOG_IDENTIFIER":"systemd","UNIT":"` + unit + `","MESSAGE_ID":"d9b373ed55a64feb8242e02dbe79a49c","MESSAGE":"m"}`
		if e := parse(t, line); e.Event == nil {
			t.Errorf("%s: no event", unit)
		}
	}
}

func TestEveryUnitMessageID(t *testing.T) {
	for id, change := range events.UnitMessages {
		line := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"1","SYSLOG_IDENTIFIER":"systemd","UNIT":"x.service","MESSAGE_ID":"` + id + `","MESSAGE":"m"}`
		if e := parse(t, line); e.Event == nil || e.Event.Change != change {
			t.Errorf("%s: got %+v, want change %q", id, e.Event, change)
		}
	}
}

func TestKernelEvents(t *testing.T) {
	want(t, parse(t, linkUp), events.Event{Time: us(1794151429841620), Kind: events.Kernel, Subject: "eno25", Change: "link-up", Message: "igb 0000:01:00.1 eno25: igb: eno25 NIC Link is Up 100 Mbps Full Duplex, Flow Control: RX/TX"})
	down := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"2","_TRANSPORT":"kernel","PRIORITY":"6","MESSAGE":"mlx4_en: ens9d1: NIC Link is Down"}`
	want(t, parse(t, down), events.Event{Time: us(2), Kind: events.Kernel, Subject: "ens9d1", Change: "link-down", Message: "mlx4_en: ens9d1: NIC Link is Down"})
	want(t, parse(t, warning), events.Event{Time: us(1794162996630751), Kind: events.Kernel, Subject: "kernel", Change: "warning", Message: "zfs: module license taints kernel."})
	for _, p := range []string{"0", "1", "2", "3"} {
		line := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"3","_TRANSPORT":"kernel","PRIORITY":"` + p + `","MESSAGE":" oops "}`
		want(t, parse(t, line), events.Event{Time: us(3), Kind: events.Kernel, Subject: "kernel", Change: "error", Message: "oops"})
	}
}

func TestPackageEvents(t *testing.T) {
	want(t, parse(t, upgraded), events.Event{Time: us(1794166900000000), Kind: events.Package, Subject: "linux", Change: "upgraded", Message: "linux"})
	for tag, change := range events.HookTags {
		line := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"4","SYSLOG_IDENTIFIER":"` + tag + `","MESSAGE":"zfs-dkms"}`
		want(t, parse(t, line), events.Event{Time: us(4), Kind: events.Package, Subject: "zfs-dkms", Change: change, Message: "zfs-dkms"})
	}
}

func TestIgnoredEntriesKeepCursorAndTime(t *testing.T) {
	for _, line := range []string{
		exited, // a MESSAGE_ID we do not react to
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","_TRANSPORT":"kernel","PRIORITY":"6","MESSAGE":"usb 1-1: new device"}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"sshd","PRIORITY":"3","MESSAGE":"error: auth"}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"systemd","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"no UNIT field"}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"lightpath-alpm-upgrade","MESSAGE":"   "}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"systemd","UNIT":"var-lib-docker-x-merged.mount","MESSAGE_ID":"7ad2d189f7e94e70a38c781354912448","MESSAGE":"Deactivated successfully."}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"systemd","UNIT":"session-3.scope","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"Started"}`,
		`{"__CURSOR":"s=9","__REALTIME_TIMESTAMP":"5","SYSLOG_IDENTIFIER":"systemd","UNIT":"user.slice","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"Started"}`,
	} {
		e := parse(t, line)
		if e.Event != nil {
			t.Errorf("unexpected event %+v for %s", *e.Event, line)
		}
		if e.Cursor == "" || e.Time.IsZero() {
			t.Errorf("cursor/time lost for %s", line)
		}
	}
	if e := parse(t, exited); e.Cursor != "s=1;i=b" || !e.Time.Equal(us(1794166897782674)) {
		t.Errorf("cursor/time = %q %v", e.Cursor, e.Time)
	}
}

func TestByteArrayMessage(t *testing.T) {
	// "eno25 NIC Link is Up" as journal byte array, with one invalid UTF-8 byte.
	msg := `[101,110,111,50,53,32,78,73,67,32,76,105,110,107,32,105,115,32,85,112,255]`
	line := `{"__CURSOR":"c","__REALTIME_TIMESTAMP":"6","_TRANSPORT":"kernel","PRIORITY":"6","MESSAGE":` + msg + `}`
	e := parse(t, line)
	if e.Event == nil || e.Event.Change != "link-up" || e.Event.Subject != "eno25" {
		t.Fatalf("got %+v", e.Event)
	}
}

func TestMalformed(t *testing.T) {
	for _, line := range []string{
		``, `not json`, `[]`,
		`{"__REALTIME_TIMESTAMP":"1"}`,
		`{"__CURSOR":"c"}`,
		`{"__CURSOR":"c","__REALTIME_TIMESTAMP":"soon"}`,
	} {
		if _, err := events.Parse([]byte(line)); !errors.Is(err, events.ErrMalformed) {
			t.Errorf("%q: err = %v, want ErrMalformed", line, err)
		}
	}
}
