output "ids" {
  value       = { for k, a in azurerm_storage_account.this : k => a.id }
  description = "Role to storage account resource ID."
}

output "blob_endpoints" {
  value       = { for k, a in azurerm_storage_account.this : k => a.primary_blob_endpoint }
  description = "Role to blob endpoint."
}
