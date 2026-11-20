# Architecture 02 storage rules, checked on a plan with a mocked provider: no Azure access needed.

mock_provider "azurerm" {
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/mock"
    }
  }
}

variables {
  accounts            = { landing = "tlnd", clientip = "tcip", records = "trec", platform = "tplat" }
  resource_group_name = "rg"
  location            = "eastus2"
  portal_origins      = ["https://portal.example.test"]
}

run "storage_rules" {
  command = plan

  assert {
    condition     = alltrue([for a in azurerm_storage_account.this : !a.shared_access_key_enabled])
    error_message = "Shared key access must be off."
  }
  assert {
    condition     = alltrue([for a in azurerm_storage_account.this : !a.public_network_access_enabled && !a.allow_nested_items_to_be_public])
    error_message = "Public network and anonymous access must be off."
  }
  assert {
    condition     = alltrue([for a in azurerm_storage_account.this : a.blob_properties[0].versioning_enabled && a.blob_properties[0].change_feed_enabled])
    error_message = "Versioning and change feed must be on."
  }
  assert {
    condition     = alltrue([for a in azurerm_storage_account.this : length(a.immutability_policy) == 1])
    error_message = "Version-level immutability support must be on."
  }
  assert {
    condition     = alltrue([for a in azurerm_storage_account.this : a.access_tier != "Archive"])
    error_message = "Never the Archive tier (ADR 0007)."
  }
  assert {
    condition     = length(azurerm_storage_account.this["landing"].blob_properties[0].cors_rule) == 1 && length(azurerm_storage_account.this["records"].blob_properties[0].cors_rule) == 0
    error_message = "CORS only on the landing account."
  }
  assert {
    condition     = length(azurerm_storage_container.platform) == 3
    error_message = "Platform containers only on the platform account."
  }
}

run "rejects_wrong_roles" {
  command = plan
  variables {
    accounts = { landing = "tlnd", clientip = "tcip", records = "trec" }
  }
  expect_failures = [var.accounts]
}
