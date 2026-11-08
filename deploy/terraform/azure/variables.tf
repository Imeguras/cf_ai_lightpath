# Account values live in terraform.tfvars (gitignored, see the .example);
# the app's secrets come from .env through the Makefile (TF_VAR_*).

variable "subscription_id" {
  description = "Azure subscription id."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "northeurope"
}

variable "image" {
  description = "The web app image, e.g. ghcr.io/<owner>/cf_ai_lightpath:<git sha> (public package)."
  type        = string
}

variable "budget_email" {
  description = "Where the budget alert goes."
  type        = string
  sensitive   = true
}

variable "budget_start" {
  description = "First day of the budget's first month (RFC 3339)."
  type        = string
  default     = "2026-11-01T00:00:00Z"
}

variable "secret_key_base" {
  description = "SECRET_KEY_BASE from .env."
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "LIGHTPATH_JWT_SECRET from .env (shared with the Worker)."
  type        = string
  sensitive   = true
}

variable "worker_url" {
  description = "LIGHTPATH_WORKER_URL from .env: the deployed Worker; empty hides the Explain button."
  type        = string
  default     = ""
}
