package daemon

import (
	"bufio"
	"io"

	"lightpath/probe/events"
)

// Consume reads `journalctl --output=json` lines from r until EOF or a read
// error, observing every event (see Observe) and calling save with the
// cursor of each entry read, so a restart can resume after it. Lines that
// are not journal entries are skipped. It returns the read error, or nil at
// EOF; an Observe error stops it and is returned.
func (d *Daemon) Consume(r io.Reader, save func(cursor string)) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		entry, err := events.Parse(sc.Bytes())
		if err != nil {
			continue
		}
		if entry.Event != nil {
			if err := d.Observe(*entry.Event); err != nil {
				return err
			}
		}
		save(entry.Cursor)
	}
	return sc.Err()
}
