# The Lightpath Worker and everything bound to it. This file is the single
# source of truth for bindings: wrangler.tf renders worker/wrangler.jsonc
# (local dev) from the same locals.

locals {
  name = "lightpath"
  # The newest date the pinned workerd supports (see worker/Dockerfile.dev).
  compatibility_date = "2026-10-18"

  # Built by `make bundle` (esbuild) from worker/src/index.ts.
  bundle = "${path.module}/../../../worker/dist/index.js"

  # Durable Objects, binding => class. All SQLite-backed.
  durable_objects = {
    SESSION    = "Session"   # chat memory, one per conversation
    LEDGER     = "Ledger"    # rough daily neuron estimate (display only)
    NEWS_STORE = "NewsStore" # package list and Arch news digests
  }

  # Workflows, binding => name and class.
  workflows = {
    TRIAGE = { name = "lightpath-triage", class = "TriageWorkflow" }
    NEWS   = { name = "lightpath-news", class = "NewsWorkflow" }
  }

  # Per visitor (the JWT's sub): AI requests per minute.
  rate_limit = { namespace_id = "1001", limit = 10, period = 60 }

  # Daily Arch news digest, 06:00 UTC.
  crons = ["0 6 * * *"]

  gateway = "lightpath"
}

resource "cloudflare_workers_script" "lightpath" {
  account_id         = var.account_id
  script_name        = local.name
  content_file       = local.bundle
  content_sha256     = filesha256(local.bundle)
  main_module        = "index.js"
  compatibility_date = local.compatibility_date

  bindings = concat(
    [
      { name = "AI", type = "ai" },
      { name = "AI_GATEWAY", type = "plain_text", text = local.gateway },
      { name = "JWT_SECRET", type = "secret_text", text = var.jwt_secret },
      {
        name         = "RATE_LIMITER"
        type         = "ratelimit"
        namespace_id = local.rate_limit.namespace_id
        simple       = { limit = local.rate_limit.limit, period = local.rate_limit.period }
      },
    ],
    [for binding, class in local.durable_objects :
      { name = binding, type = "durable_object_namespace", class_name = class }
    ],
    [for binding, w in local.workflows :
      { name = binding, type = "workflow", workflow_name = w.name, class_name = w.class }
    ],
  )

  # First deploy creates every class. A later class change adds a migration
  # step here (new_tag "v2", ...) and to wrangler.tf.
  migrations = {
    new_tag            = "v1"
    new_sqlite_classes = values(local.durable_objects)
  }

  observability = { enabled = true }
}

resource "cloudflare_workflow" "lightpath" {
  for_each = local.workflows

  account_id    = var.account_id
  workflow_name = each.value.name
  class_name    = each.value.class
  script_name   = cloudflare_workers_script.lightpath.script_name
}

resource "cloudflare_workers_cron_trigger" "lightpath" {
  account_id  = var.account_id
  script_name = cloudflare_workers_script.lightpath.script_name
  schedules   = [for c in local.crons : { cron = c }]
}

# Serve on <name>.<account subdomain>.workers.dev (no custom domain yet).
resource "cloudflare_workers_script_subdomain" "lightpath" {
  account_id       = var.account_id
  script_name      = cloudflare_workers_script.lightpath.script_name
  enabled          = true
  previews_enabled = false
}

# Workers AI calls go through this gateway (env.AI_GATEWAY): identical
# prompts are answered from cache for an hour, and it caps requests overall
# on top of the Worker's per-visitor limit. No request logging.
resource "cloudflare_ai_gateway" "lightpath" {
  account_id                 = var.account_id
  id                         = local.gateway
  cache_ttl                  = 3600
  cache_invalidate_on_update = true
  collect_logs               = false
  rate_limiting_interval     = 60
  rate_limiting_limit        = 30
  rate_limiting_technique    = "sliding"
}
