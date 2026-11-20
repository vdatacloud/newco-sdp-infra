variable "names" {
  type = object({
    vnet   = string
    nsg    = string
    nat    = string
    nat_ip = string
    pe     = string
    router = string
  })
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = string
}

variable "pe_subnet" {
  type = string
}

variable "router_subnet" {
  type = string
}

variable "storage_account_ids" {
  type        = map(string)
  description = "Role to storage account ID; each gets a blob private endpoint."
}

variable "key_vault_id" {
  type = string
}

variable "router_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "B-series is not offered to the dev subscription in eastus2 (2026-11-20); D2s_v5 is the smallest allowed size."
}

variable "router_shutdown_time" {
  type        = string
  default     = "1900"
  description = "Daily auto-shutdown (HHMM) in router_shutdown_timezone; start it again with make azure-router-start."
}

variable "router_shutdown_timezone" {
  type    = string
  default = "Eastern Standard Time"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Break-glass SSH key; day-to-day access is Tailscale SSH."
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "router_zone" {
  type        = string
  default     = "2"
  description = "D2s_v5 in eastus2 is offered to the dev subscription only in zone 2 (2026-11-20)."
}
