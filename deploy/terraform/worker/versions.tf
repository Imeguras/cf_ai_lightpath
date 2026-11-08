terraform {
  required_version = ">= 1.10"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.14"
    }
    # Writes worker/wrangler.jsonc (local dev config) from the same locals.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# The everyday token (CLOUDFLARE_API_TOKEN in .env, made by ../token.tf).
# The Makefile passes it, and everything else from .env, as TF_VAR_*.
provider "cloudflare" {
  api_token = var.api_token
}
