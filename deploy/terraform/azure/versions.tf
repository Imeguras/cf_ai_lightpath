terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
  }
}

# Auth: whatever azurerm finds; `az login` once, or a service principal in
# ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID. No az commands are
# needed beyond that.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  # Register only what main.tf needs (below), not the provider's long
  # default list.
  resource_provider_registrations = "none"
}
