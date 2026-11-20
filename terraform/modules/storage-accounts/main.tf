# Storage subset of the regional stamp (architecture 02): one account per role, data plane private,
# Entra-only access. Per-tenant containers and encryption scopes are created by core's provisioner, not here.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_storage_account" "this" {
  for_each = var.accounts

  name                     = each.value
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  access_tier              = "Hot"

  # Entra ID only (user delegation SAS); no shared key, no anonymous containers, no public endpoint.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  is_hns_enabled                  = false # blob index tags and version-level WORM need flat namespace

  # Enables version-level immutability support; policies (legal hold, locked retention) are set per version
  # by the locker. "Disabled" means no account-wide default policy.
  immutability_policy {
    allow_protected_append_writes = false
    state                         = "Disabled"
    period_since_creation_in_days = 1
  }

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = var.soft_delete_days
    }
    container_delete_retention_policy {
      days = var.soft_delete_days
    }

    dynamic "cors_rule" {
      for_each = each.key == "landing" && length(var.portal_origins) > 0 ? [1] : []
      content {
        allowed_methods    = ["PUT", "OPTIONS"]
        allowed_origins    = var.portal_origins
        allowed_headers    = ["x-ms-blob-type", "x-ms-version", "x-ms-date", "content-type", "content-length", "x-ms-client-request-id"]
        exposed_headers    = ["etag", "x-ms-request-id"]
        max_age_in_seconds = 3600
      }
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

# Platform containers go through Resource Manager (storage_account_id), so they need no data-plane access.
resource "azurerm_storage_container" "platform" {
  for_each = toset(var.platform_containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this["platform"].id
  container_access_type = "private"
}
