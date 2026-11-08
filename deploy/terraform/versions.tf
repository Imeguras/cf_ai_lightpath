terraform {
  required_version = ">= 1.10"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # 5.14 fixed Durable Object migrations; Workflows need >= 5.11.
      version = "~> 5.14"
    }
  }
}

# Creating API tokens needs a separate bootstrap token ("Create Additional
# Tokens" template). It lives in terraform.tfvars (gitignored), not in .env,
# so the everyday token in .env can never create other tokens.
provider "cloudflare" {
  api_token = var.bootstrap_api_token
}
