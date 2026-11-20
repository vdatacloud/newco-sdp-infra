# Azure dev storage and Key Vault (infra I3a, R3). Written and checked only: nothing is applied until the
# private network (I3c) exists (I3b). Non-secret values come from config/environments/<env>.yaml.
# Run through make (azure-check, azure-plan), which supplies the certificate password from the keychain.

terraform {
  # Bootstrap: local, gitignored state (local/terraform-<env>-storage.tfstate); moves to a private state
  # account with I3c.
  backend "local" {}
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

variable "env_file" {
  type        = string
  default     = "../../../config/environments/azdev.yaml"
  description = "Environment definition, relative to this directory."
}

variable "client_certificate_password" {
  type      = string
  sensitive = true
  default   = null
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "One-off, pre-approved, short-lived key for the subnet router (keychain item tailscale-sdp-dev)."
}

variable "workload_principal_id" {
  type        = string
  default     = null
  description = "Overrides azure.workload_principal_id from the environment file. Empty: no role assignments."
}

locals {
  env    = yamldecode(file("${path.module}/${var.env_file}"))
  n      = local.env.naming
  azure  = local.env.azure
  suffix = "${local.n.instance}-${local.n.stage}"
  name   = { for t in ["rg", "kv", "vnet", "nsg", "nat", "pip", "pe", "vm"] : t => "${local.n.client}-${local.n.project}-${t}-${local.suffix}" }
  storage_names = {
    for role, a in local.env.storage.accounts :
    role => "${local.n.client}${local.n.project}${a.short}${local.n.instance}${local.n.stage}"
  }
  workload_principal_id = coalesce(var.workload_principal_id, try(local.azure.workload_principal_id, ""), "-")
  workload              = local.workload_principal_id == "-" ? "" : local.workload_principal_id
  # Owner, Project and Environment are required by Azure Policy (see azdev.yaml).
  tags = {
    Owner       = local.env.owner
    Project     = local.n.project
    Environment = local.n.stage
    Client      = local.n.client
    ManagedBy   = "terraform"
  }
}

provider "azurerm" {
  features {
    # Shared key is off and the data plane is private: never poll the blob endpoint from Terraform.
    storage {
      data_plane_available = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }

  # The Terraform principal can't register providers; Microsoft.Storage and Microsoft.KeyVault are registered
  # once by a subscription owner (az provider register).
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  subscription_id             = local.azure.subscription_id
  tenant_id                   = local.azure.tenant_id
  client_id                   = local.azure.terraform_client_id
  client_certificate_path     = pathexpand(local.azure.terraform_certificate_path)
  client_certificate_password = var.client_certificate_password
}

resource "azurerm_resource_group" "this" {
  name     = local.name.rg
  location = local.env.region
  tags     = local.tags
}

module "storage" {
  source              = "../../modules/storage-accounts"
  accounts            = local.storage_names
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  portal_origins      = try(local.azure.portal_origins, [])
  tags                = local.tags
}

module "network" {
  source = "../../modules/dev-network"
  names = {
    vnet   = local.name.vnet, nsg = local.name.nsg, nat = local.name.nat, nat_ip = local.name.pip, pe = local.name.pe,
    router = local.name.vm
  }
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  address_space        = local.env.network.address_space
  pe_subnet            = local.env.network.pe_subnet
  router_subnet        = local.env.network.router_subnet
  storage_account_ids  = module.storage.ids
  key_vault_id         = azurerm_key_vault.this.id
  admin_ssh_public_key = file(pathexpand(local.env.network.admin_ssh_public_key_path))
  tailscale_auth_key   = var.tailscale_auth_key
  tags                 = local.tags
}

check "tailscale_key" {
  assert {
    condition     = var.tailscale_auth_key != ""
    error_message = "No Tailscale auth key: the router will not join the tailnet. Store one as keychain item tailscale-sdp-dev before apply."
  }
}

resource "azurerm_key_vault" "this" {
  name                          = local.name.kv
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  tenant_id                     = local.azure.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = local.tags
}

# Receipt signing key (core keyvault.signingkey = "receipts"): P-256, sign and verify only. Data plane: created
# from a tailnet machine at I3b.
resource "azurerm_key_vault_key" "receipts" {
  name         = "receipts"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "EC"
  curve        = "P-256"
  key_opts     = ["sign", "verify"]
}

# Dev workload principal: Blob Data Owner (user delegation keys, holds, tags) and Crypto User.
resource "azurerm_role_assignment" "blob_owner" {
  for_each             = local.workload == "" ? {} : module.storage.ids
  scope                = each.value
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.workload
}

# Per-tenant encryption scopes (core L2a). The role is custom
# (config/azure-roles/sdp-encryption-scope-writer.json, created once by an owner,
# docs/AZURE_DEV.md). On AKS it moves to a separate onboarding identity: write
# can also disable a scope, which the API identity should not be able to do.
resource "azurerm_role_assignment" "scope_writer" {
  # Tenant accounts only: the platform account holds no tenant data.
  for_each             = local.workload == "" ? {} : { for k, v in module.storage.ids : k => v if k != "platform" }
  scope                = each.value
  role_definition_name = "SDP Encryption Scope Writer"
  principal_id         = local.workload
}

# Tenant name keys are vault secrets (core TD-12): the locker reads them and,
# on azdev, devseed (same identity) creates them. On AKS reading and creating
# split between the locker (Secrets User) and onboarding (Secrets Officer).
resource "azurerm_role_assignment" "secrets_officer" {
  count                = local.workload == "" ? 0 : 1
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = local.workload
}

resource "azurerm_role_assignment" "crypto_user" {
  count                = local.workload == "" ? 0 : 1
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = local.workload
}

output "storage_accounts" {
  value = local.storage_names
}

output "router_ip" {
  value = module.network.router_ip
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}
