# The public demo: the web app with the public fixtures baked in, on Azure
# Container Apps. It scales to zero when nobody visits (the free monthly
# grant covers a reviewer's visits), keeps no logs, and alerts by email
# before it can cost anything.

locals {
  name = "lightpath"
  port = 4100
}

# Container Apps' resource provider; the subscription starts without it.
resource "azurerm_resource_provider_registration" "app" {
  name = "Microsoft.App"
}

resource "azurerm_resource_group" "lightpath" {
  name     = "${local.name}-demo"
  location = var.location
}

# No logs_destination: logs are streamed only, never stored (no Log
# Analytics workspace, so nothing to bill or to leak).
resource "azurerm_container_app_environment" "lightpath" {
  depends_on          = [azurerm_resource_provider_registration.app]
  name                = "${local.name}-env"
  location            = azurerm_resource_group.lightpath.location
  resource_group_name = azurerm_resource_group.lightpath.name
}

resource "azurerm_container_app" "lightpath" {
  name                         = local.name
  container_app_environment_id = azurerm_container_app_environment.lightpath.id
  resource_group_name          = azurerm_resource_group.lightpath.name
  revision_mode                = "Single"

  secret {
    name  = "secret-key-base"
    value = var.secret_key_base
  }
  secret {
    name  = "jwt-secret"
    value = var.jwt_secret
  }

  ingress {
    external_enabled = true
    target_port      = local.port
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = local.name
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "SECRET_KEY_BASE"
        secret_name = "secret-key-base"
      }
      env {
        name        = "LIGHTPATH_JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "LIGHTPATH_WORKER_URL"
        value = var.worker_url
      }
      env {
        name  = "PORT"
        value = tostring(local.port)
      }
      # LiveView only accepts its websocket from this host: the app's own
      # name, known before the app exists (name + environment domain).
      env {
        name  = "PHX_HOST"
        value = "${local.name}.${azurerm_container_app_environment.lightpath.default_domain}"
      }
    }
  }
}

# 1 (in the subscription's currency) per month; email at 50% and 100%.
resource "azurerm_consumption_budget_resource_group" "lightpath" {
  name              = "${local.name}-budget"
  resource_group_id = azurerm_resource_group.lightpath.id
  amount            = 1
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start
  }

  notification {
    operator       = "GreaterThanOrEqualTo"
    threshold      = 50
    contact_emails = [var.budget_email]
  }
  notification {
    operator       = "GreaterThanOrEqualTo"
    threshold      = 100
    contact_emails = [var.budget_email]
  }
}

output "url" {
  value = "https://${azurerm_container_app.lightpath.ingress[0].fqdn}"
}
