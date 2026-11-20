# Architecture 02 rules, checked on a plan with a mocked provider: no Azure access needed.

mock_provider "azurerm" {
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/mock"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/mock"
      vault_uri = "https://mock.vault.azure.net/"
    }
  }
}

variables {
  workload_principal_id = "11111111-1111-1111-1111-111111111111"
}

run "stamp_rules" {
  command = plan

  assert {
    condition     = length(module.storage.ids) == 4
    error_message = "Four storage accounts: landing, clientip, records, platform."
  }
  assert {
    condition     = local.storage_names.landing == "newcosdplnd1dev" && local.name.kv == "newco-sdp-kv-1-dev"
    error_message = "Names follow <client><project><role><instance><stage>."
  }
  assert {
    condition     = !azurerm_key_vault.this.public_network_access_enabled && azurerm_key_vault.this.rbac_authorization_enabled && azurerm_key_vault.this.purge_protection_enabled
    error_message = "Key Vault: RBAC, purge protection, no public access."
  }
  assert {
    condition     = azurerm_key_vault_key.receipts.key_type == "EC" && azurerm_key_vault_key.receipts.curve == "P-256"
    error_message = "Receipt key is P-256 (core custody ES256)."
  }
  assert {
    condition     = length(azurerm_role_assignment.blob_owner) == 4 && length(azurerm_role_assignment.crypto_user) == 1
    error_message = "Workload principal gets Blob Data Owner on each account and Crypto User on the vault."
  }
}
