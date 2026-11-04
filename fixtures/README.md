# Fixtures

Recorded output of the read-only inventory (`probe/cmd/inventory`), used as
evidence by the scorer and as the data behind the public demo.

- `raw/` is the unscrubbed output. It is gitignored and never published.
- `public/` is what `probe/cmd/scrub` makes of it.

## public/zfs-down-2026-11-04

55 commands run as an unprivileged user on the homelab server on 2026-11-04,
while ZFS was down: the running kernel (7.2.14) is newer than the newest one
zfs-dkms 2.4.0 supports (`Linux-Maximum: 6.18`), so the module was never
built and the pools are not imported. It is the validation case for the
diagnosis: nothing was fixed before or during the recording.

### What was scrubbed

Every value below was replaced by a stable placeholder, so the same value
always maps to the same placeholder across files:

| Kind | Placeholder |
|---|---|
| Host, user, pool and people's names | plain words: `labhost`, `labuser`, `pool_a`, ... |
| IPv4 addresses | documentation ranges `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` |
| IPv6 addresses | `2001:db8::/32` |
| MAC / InfiniBand hardware addresses | `02:00:...` with the original length |
| 64-bit IDs (InfiniBand GUIDs, kernel addresses) | `0x02000000xxxxxxxx` |
| UUIDs | `00000000-0000-4000-8000-...` |
| Email addresses | `userN@example.invalid` |

Kept on purpose: loopback and unspecified addresses, package and firmware
versions (`1.2.3.4-1`), and systemd unit names (`getty@tty1.service`).
