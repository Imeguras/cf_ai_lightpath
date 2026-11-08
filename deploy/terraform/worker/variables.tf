# All set from .env by the Makefile (TF_VAR_*), so each value has one home.

variable "api_token" {
  description = "CLOUDFLARE_API_TOKEN: the token made by ../token.tf."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "CLOUDFLARE_ACCOUNT_ID."
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "LIGHTPATH_JWT_SECRET: the HS256 secret the web app signs its tokens with."
  type        = string
  sensitive   = true
}
