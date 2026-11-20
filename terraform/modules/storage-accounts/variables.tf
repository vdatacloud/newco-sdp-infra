variable "accounts" {
  type        = map(string)
  description = "Role (landing, clientip, records, platform) to storage account name."
  validation {
    condition     = toset(keys(var.accounts)) == toset(["landing", "clientip", "records", "platform"])
    error_message = "accounts must name exactly landing, clientip, records and platform."
  }
  validation {
    condition     = alltrue([for n in values(var.accounts) : can(regex("^[a-z0-9]{3,24}$", n))])
    error_message = "Storage account names are 3 to 24 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "replication_type" {
  type        = string
  default     = "LRS"
  description = "LRS for dev; the regional stamp (L2) chooses per region."
}

variable "soft_delete_days" {
  type    = number
  default = 7
}

variable "portal_origins" {
  type        = list(string)
  default     = []
  description = "Browser origins allowed to PUT to the landing account."
}

variable "platform_containers" {
  type    = list(string)
  default = ["bundles", "manifests", "testplans"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
