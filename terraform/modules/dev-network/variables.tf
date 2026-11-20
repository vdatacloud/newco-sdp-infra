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
  type    = string
  default = "Standard_B1s"
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
