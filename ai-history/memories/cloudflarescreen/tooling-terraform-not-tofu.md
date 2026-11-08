---
name: tooling-terraform-not-tofu
description: Infra-as-code is HashiCorp Terraform (extra/terraform), never OpenTofu; keep vendor CLIs (wrangler etc.) out of the deploy path
metadata:
  type: feedback
---

Use **Terraform** (`extra/terraform`, the `cloudflare/cloudflare` provider) for infrastructure. Don't propose or write OpenTofu.

**Why:** the user (2026-11-04): "I said no OpenTofu though... i want terraform its the one i know." He also doesn't want to depend on vendor-specific CLIs (wrangler, gcloud, aws, az): too many to learn and memorise.

**How to apply:** deploy = esbuild bundle + Terraform + an API token from `.env` (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`). wrangler is allowed only as an optional local-dev convenience. Wrap every workflow in `make` targets so the repo, not his memory, holds the commands. Related: [[single-config-knob]].

Also (2026-11-05): .tf is the single source of truth for Worker bindings, DO migrations, Workflows and crons; wrangler.jsonc is dev-only and derived from or checked against the .tf.
