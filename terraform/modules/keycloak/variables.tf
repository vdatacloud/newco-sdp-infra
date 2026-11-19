variable "audience" {
  description = "Audience every SDP token carries (§04)."
  type        = string
  default     = "locker-api"
}

variable "ssl_required" {
  description = "Realm ssl_required: none for the local stack, external elsewhere."
  type        = string
  default     = "external"
}

variable "service_clients" {
  description = "Confidential client-credentials clients in the lab realm. Include one outside the locker's capability map for the negative test."
  type        = list(string)
  default     = ["locker", "seal-worker"]
}

variable "dev_users_enabled" {
  description = "Create the dev-cli password-grant clients and dev_users. Never true outside dev."
  type        = bool
  default     = false
}

variable "dev_users" {
  description = "Dev test users keyed by username: realm, realm roles, and org (tenant UUID, clients realm only)."
  type = map(object({
    realm = string
    roles = list(string)
    org   = optional(string)
  }))
  default = {}
}
