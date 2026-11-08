---
name: cap-drop-reminder
description: Containers use cap_drop ALL; when anything fails with permission errors, remind the user that the capability drop is a likely cause
metadata:
  type: feedback
---

compose.yaml drops all Linux capabilities (plus read_only and no-new-privileges). the user (2026-11-04): dropping all caps is the harsher security move, so if something fails because of it, remind him.

**Why:** a failure caused by a missing capability looks like an unrelated bug ("operation not permitted", a bind or chown failing), and he wants the link made for him.
**How to apply:** whenever a container fails with EPERM/EACCES, a bind error, or a tool that needs raw sockets or chown, say explicitly that `cap_drop: ALL` may be the cause, and name the single capability to add back. Don't add it back silently. Related: [[homeserver-docker-rootless]].
