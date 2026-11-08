---
name: kill-processes-visibly
description: Stop processes with ps -ef | grep X, read the PID, then kill -9 PID; never pkill or pgrep -f
metadata:
  type: feedback
---

To stop a process: run `ps -ef | grep X`, read the PID from the listing, then `kill -9 <pid>`. Don't use `pkill` or `pgrep -f`.

**Why:** on 2026-11-04 `pkill -f 'wrangler dev ...'` and `pgrep -f 'node.*wrangler'` matched the shell running them and killed the tool command twice (exit 144). the user: with ps + kill "you may end up not doing anything, at least this way you know it hit or missed something."

**How to apply:** list first and show the matching lines, pick the PIDs explicitly (not the grep line itself), then kill them. Kill the parent (supervisor) first, then its children, and list again: wrangler respawned the workerd processes killed under it, and kill -9 on a launcher leaves the real process orphaned. Prefer background tasks (run_in_background) for servers so they have a known handle.

Also (2026-11-08): never pipe `ps -ef | grep X` straight into kill in the same command: the shell running that command line contains X too and gets killed (happened with an `az login` cleanup). List first, read the PIDs, then kill only those PIDs in a separate step.
