# I3c rules on a plan with a mocked provider: no Azure access needed.

mock_provider "azurerm" {}

variables {
  names               = { vnet = "vnet", nsg = "nsg", nat = "nat", nat_ip = "pip", pe = "pe", router = "vm" }
  resource_group_name = "rg"
  location            = "eastus2"
  address_space       = "10.42.0.0/16"
  pe_subnet           = "10.42.1.0/24"
  router_subnet       = "10.42.2.0/27"
  storage_account_ids = {
    landing  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/a"
    clientip = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/b"
  }
  key_vault_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPi6oUFN9Aq2y4VwbDXimvED1Sa5yjk0+PzxjWYSdNCS test-only"
  tailscale_auth_key   = "tskey-test"
}

run "network_rules" {
  command = plan

  assert {
    condition     = length(azurerm_private_endpoint.blob) == 2 && azurerm_private_endpoint.vault.private_service_connection[0].subresource_names[0] == "vault"
    error_message = "A blob endpoint per account and a vault endpoint."
  }
  assert {
    condition     = toset([for z in azurerm_private_dns_zone.this : z.name]) == toset(["privatelink.blob.core.windows.net", "privatelink.vaultcore.azure.net"])
    error_message = "Private DNS zones for blob and vault."
  }
  assert {
    condition     = azurerm_network_interface.router.ip_forwarding_enabled && azurerm_network_interface.router.ip_configuration[0].public_ip_address_id == null
    error_message = "Router forwards and has no public IP."
  }
  assert {
    condition     = alltrue([for n in azurerm_network_security_group.this : anytrue([for r in n.security_rule : r.access == "Deny" && r.direction == "Inbound" && r.source_address_prefix == "Internet"])])
    error_message = "Each subnet denies inbound from the internet."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.router.disable_password_authentication
    error_message = "No password sign-in on the router."
  }
}
