---
name: single-config-knob
description: One setting should change one thing everywhere; never make the user edit the same value in two places
metadata:
  type: feedback
---

the user rejected a compose file where the container port was set in one place and the host mapping in another (2026-11-04). It's now one `LIGHTPATH_PORT` used for both.

**Why:** he'll come back to the project after long gaps and will forget the second place.
**How to apply:** when a value appears in several places (ports, hostnames, versions, paths), drive them all from one variable or hide the internal one entirely. Applies to compose, Helm values, Terraform and app config.
