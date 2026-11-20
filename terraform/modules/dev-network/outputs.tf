output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "router_ip" {
  value       = azurerm_network_interface.router.private_ip_address
  description = "Tailnet split DNS target for blob.core.windows.net and vault.azure.net."
}
