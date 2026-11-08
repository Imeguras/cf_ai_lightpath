# Every value here that identifies the account or its owner is set in
# terraform.tfvars, which is gitignored. terraform.tfvars.example shows the
# shape with fake values.

variable "bootstrap_api_token" {
  description = "Token allowed to create other tokens (dashboard template: Create Additional Tokens)."
  type        = string
  sensitive   = true
}

variable "user_id" {
  description = "Your Cloudflare user id (32 hex characters), for the user-level permissions."
  type        = string
  sensitive   = true
}

variable "allowed_ips" {
  description = "Where the token may be used from: your IPv4 as /32 and your IPv6 prefix as /64 (privacy addresses inside it rotate)."
  type        = list(string)
  sensitive   = true
}

variable "token_expires_on" {
  description = "When the token stops working (RFC 3339)."
  type        = string
  default     = "2027-11-04T23:59:59Z"
}
