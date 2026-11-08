---
name: homeserver-docker-rootless
description: The homelab server's Docker daemon is rootful (checked 2026-11-04); still keep compose/Helm choices rootless-compatible
metadata:
  type: project
---

the user wasn't sure whether Docker on the homelab server runs rootless. The phase 1 inventory settled it on 2026-11-04: `docker info` security options are `seccomp` and `cgroupns`, with no `rootless`, so the daemon is **rootful** (micron reaches it through the docker group).

**Why:** rootful means the docker group is effectively root on that box, and Docker's iptables rules (FORWARD DROP) sit next to the kubeadm/Cilium cluster.
**How to apply:** keep container ports ≥1024 and avoid privileged mode anyway, so a later switch to rootless costs nothing. Re-check with the `docker-security` inventory command if he changes the setup. Related: [[cap-drop-reminder]].
