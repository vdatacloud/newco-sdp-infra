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
  purge_principal_id    = "22222222-2222-2222-2222-222222222222"
  tailscale_auth_key    = "tskey-test"
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

run "purge_identity" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.purge_blob_owner) == 3 && !contains(keys(azurerm_role_assignment.purge_blob_owner), "platform")
    error_message = "Purge worker gets Blob Data Owner on the three tenant accounts only, not platform."
  }
  assert {
    condition     = length(azurerm_role_assignment.purge_scope_writer) == 3 && length(azurerm_role_assignment.purge_crypto_user) == 1
    error_message = "Purge worker gets Scope Writer on tenant accounts and Crypto User on the vault."
  }
  assert {
    condition     = alltrue([for a in values(azurerm_role_assignment.purge_blob_owner) : a.principal_id == "22222222-2222-2222-2222-222222222222"])
    error_message = "Purge assignments go to the purge principal, not the workload principal."
  }
}

run "no_purge_identity" {
  command = plan

  variables {
    purge_principal_id = ""
  }

  assert {
    condition     = length(azurerm_role_assignment.purge_blob_owner) == 0 && length(azurerm_role_assignment.purge_crypto_user) == 0
    error_message = "Without a purge principal, no purge role assignments."
  }
}
