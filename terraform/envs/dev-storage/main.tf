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

variable "workload_principal_id" {
  type        = string
  default     = ""
  description = "Object ID of the dev workload principal (locker and seal worker). Empty: no role assignments."
}

locals {
  env    = yamldecode(file("${path.module}/${var.env_file}"))
  n      = local.env.naming
  azure  = local.env.azure
  suffix = "${local.n.instance}-${local.n.stage}"
  name   = { for t in ["rg", "kv"] : t => "${local.n.client}-${local.n.project}-${t}-${local.suffix}" }
  storage_names = {
    for role, a in local.env.storage.accounts :
    role => "${local.n.client}${local.n.project}${a.short}${local.n.instance}${local.n.stage}"
  }
  tags = { client = local.n.client, project = local.n.project, env = local.env.env, managed_by = "terraform" }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }

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
  for_each             = var.workload_principal_id == "" ? {} : module.storage.ids
  scope                = each.value
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = var.workload_principal_id
}

resource "azurerm_role_assignment" "crypto_user" {
  count                = var.workload_principal_id == "" ? 0 : 1
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = var.workload_principal_id
}

output "storage_accounts" {
  value = local.storage_names
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}
