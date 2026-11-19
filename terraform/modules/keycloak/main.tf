# Keycloak realms for SDP (I2b). Architecture §04 "Identity": two realms, lab and clients, both issuing
# tokens with audience locker-api. The clients realm adds the org claim (tenant UUID).
#
# Deviation: org comes from a user attribute mapped to the claim, not Keycloak Organizations, so the
# claim is a bare tenant UUID and the dev realm needs no organization objects.

terraform {
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

locals {
  realms = {
    lab = {
      roles = ["tester", "reviewer", "cert_signer", "purge_approver", "lab_admin"]
    }
    clients = {
      roles = ["client_submitter", "client_viewer", "auditor"]
    }
  }
  realm_roles = merge([
    for realm, r in local.realms : { for role in r.roles : "${realm}/${role}" => { realm = realm, role = role } }
  ]...)
}

resource "keycloak_realm" "this" {
  for_each     = local.realms
  realm        = each.key
  enabled      = true
  ssl_required = var.ssl_required
  # Short-lived access tokens; the locker never accepts refresh tokens.
  access_token_lifespan = "5m"
}

resource "keycloak_role" "realm" {
  for_each = local.realm_roles
  realm_id = keycloak_realm.this[each.value.realm].id
  name     = each.value.role
}

# Audience: a client scope every client gets by default, adding locker-api to aud.
resource "keycloak_openid_client_scope" "locker_api" {
  for_each               = local.realms
  realm_id               = keycloak_realm.this[each.key].id
  name                   = "locker-api"
  include_in_token_scope = false
}

resource "keycloak_openid_audience_protocol_mapper" "locker_api" {
  for_each                 = local.realms
  realm_id                 = keycloak_realm.this[each.key].id
  client_scope_id          = keycloak_openid_client_scope.locker_api[each.key].id
  name                     = "aud-locker-api"
  included_custom_audience = var.audience
  add_to_access_token      = true
  add_to_id_token          = false
}

resource "keycloak_openid_user_attribute_protocol_mapper" "org" {
  realm_id            = keycloak_realm.this["clients"].id
  client_scope_id     = keycloak_openid_client_scope.locker_api["clients"].id
  name                = "org"
  user_attribute      = "org"
  claim_name          = "org"
  claim_value_type    = "String"
  add_to_access_token = true
  add_to_id_token     = false
  add_to_userinfo     = false
}

resource "keycloak_realm_default_client_scopes" "this" {
  for_each       = local.realms
  realm_id       = keycloak_realm.this[each.key].id
  default_scopes = ["profile", "email", "roles", "web-origins", "acr", "basic", keycloak_openid_client_scope.locker_api[each.key].name]
}

# Keycloak 26 drops undeclared attributes, so org is declared here. Only admins may view or edit it:
# a user who could set their own org could pick their tenant.
locals {
  profile_attrs = ["username", "email", "firstName", "lastName"]
}

resource "keycloak_realm_user_profile" "clients" {
  realm_id = keycloak_realm.this["clients"].id

  dynamic "attribute" {
    for_each = local.profile_attrs
    content {
      name         = attribute.value
      display_name = "$${${attribute.value}}"
      permissions {
        view = ["admin", "user"]
        edit = ["admin", "user"]
      }
    }
  }
  attribute {
    name         = "org"
    display_name = "Tenant (UUID)"
    permissions {
      view = ["admin"]
      edit = ["admin"]
    }
    validator {
      name = "pattern"
      config = {
        pattern         = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        "error-message" = "org must be a UUIDv7"
      }
    }
  }
}
