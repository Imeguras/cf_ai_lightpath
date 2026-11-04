---
name: homeserver-docker-rootless
description: Unknown whether the homelab server's Docker daemon is rootless; keep compose and Helm choices compatible with both
metadata:
  type: project
---

As of 2026-11-04, João isn't sure whether Docker on the homelab server runs rootless.

**Why:** rootless Docker changes what works: no host ports below 1024, port publishing goes through rootlesskit, cgroup limits may be unavailable, and bind-mounted file ownership maps to subuids.
**How to apply:** keep container ports ≥1024, avoid privileged mode and host device mounts in compose, and check the daemon mode (`docker info` shows "rootless" under Security Options) before anything that depends on it on the server. Related: [[cap-drop-reminder]].
