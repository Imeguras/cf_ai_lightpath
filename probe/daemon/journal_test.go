package daemon_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConsumeObservesEventsAndSavesCursors(t *testing.T) {
	d, r, c, dir := setup(t)
	d.Probe(context.Background(), nil)
	stream := strings.Join([]string{
		`{"__CURSOR":"c1","__REALTIME_TIMESTAMP":"1794166900000000","SYSLOG_IDENTIFIER":"sshd","MESSAGE":"noise"}`,
		`garbage`,
		`{"__CURSOR":"c2","__REALTIME_TIMESTAMP":"1794166900000001","SYSLOG_IDENTIFIER":"lightpath-alpm-upgrade","MESSAGE":"linux"}`,
		``,
	}, "\n")
	var cursors []string
	if err := d.Consume(strings.NewReader(stream), func(c string) { cursors = append(cursors, c) }); err != nil {
		t.Fatal(err)
	}
	if strings.Join(cursors, ",") != "c1,c2" {
		t.Fatalf("cursors %v", cursors)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "events", "events-2026-11-08.jsonl"))
	if !strings.Contains(string(b), `"subject":"linux"`) || strings.Contains(string(b), "noise") {
		t.Fatalf("timeline: %s", b)
	}
	c.add(time.Minute)
	if name, _ := d.Tick(context.Background()); name == "" || r.count("uname") != 2 {
		t.Fatalf("the package event did not queue its probes: %q %v", name, r.calls)
	}
}
