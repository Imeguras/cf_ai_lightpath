Draft by Claude (2026-11-08), not reviewed yet.

Gigabit needs all four pairs. Swap the cable for a known-good Cat5e/Cat6
patch lead (short, factory-made), then check:

  ethtool eno25 | grep -E 'Speed|Duplex'

Expect 1000Mb/s Full. Still 100: it is the other end (see the next cause).
