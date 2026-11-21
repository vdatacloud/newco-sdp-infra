# Dev realms on the local stack (keycloak-<env>). Run through make idp-apply, which supplies the admin
# password from local/.env.<env>. State is local and gitignored (local/terraform-<env>.tfstate).

terraform {
  # Path set by make idp-apply: local/terraform-<env>.tfstate (gitignored).
  backend "local" {}
  required_version = ">= 1.9"
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

variable "keycloak_url" {
  type    = string
  default = "http://127.0.0.1:18180"
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = var.keycloak_admin_password
  url       = var.keycloak_url
}

module "keycloak" {
  source       = "../../modules/keycloak"
  ssl_required = "none"
  # sdp-probe sits outside the locker's capability map: L3's negative test.
  service_clients   = ["locker", "seal-worker", "purge-worker", "sdp-probe"]
  dev_users_enabled = true
  dev_users = {
    # Fake fixtures; devseed tenant1 is 0193a000-0000-7000-8000-000000000001.
    "dev-tester"  = { realm = "lab", roles = [] } # rights from devseed assignments
    "dev-admin"   = { realm = "lab", roles = [] }
    "dev-client1" = { realm = "clients", roles = ["client_submitter"], org = "0193a000-0000-7000-8000-000000000001" }
  }
}

output "issuers" {
  value = { for k, p in module.keycloak.issuers : k => "${var.keycloak_url}${p}" }
}

output "service_client_secrets" {
  value     = module.keycloak.service_client_secrets
  sensitive = true
}

output "dev_user_passwords" {
  value     = module.keycloak.dev_user_passwords
  sensitive = true
}
