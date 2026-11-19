# Clients. Service clients use client credentials in the lab realm; locker-upload is a public
# device-flow client in the clients realm (SDK uploads). A client's own scopes do not grant capabilities:
# the locker's capability map decides what each service may call (§04).

resource "keycloak_openid_client" "service" {
  for_each                     = toset(var.service_clients)
  realm_id                     = keycloak_realm.this["lab"].id
  client_id                    = each.key
  name                         = each.key
  enabled                      = true
  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
}

resource "keycloak_openid_client_default_scopes" "service" {
  for_each       = keycloak_openid_client.service
  realm_id       = keycloak_realm.this["lab"].id
  client_id      = each.value.id
  default_scopes = ["roles", "acr", "basic", keycloak_openid_client_scope.locker_api["lab"].name]
}

resource "keycloak_openid_client" "upload" {
  realm_id                                  = keycloak_realm.this["clients"].id
  client_id                                 = "locker-upload"
  name                                      = "locker-upload"
  enabled                                   = true
  access_type                               = "PUBLIC"
  standard_flow_enabled                     = false
  direct_access_grants_enabled              = false
  oauth2_device_authorization_grant_enabled = true
}

# Dev-only: a password-grant client per realm so tests can fetch user tokens without a browser.
resource "keycloak_openid_client" "dev_cli" {
  for_each                     = var.dev_users_enabled ? local.realms : {}
  realm_id                     = keycloak_realm.this[each.key].id
  client_id                    = "dev-cli"
  name                         = "dev-cli (dev only)"
  enabled                      = true
  access_type                  = "PUBLIC"
  standard_flow_enabled        = false
  direct_access_grants_enabled = true
}

# Realm default scopes reach only clients created after them, so each client lists its own.
resource "keycloak_openid_client_default_scopes" "upload" {
  realm_id       = keycloak_realm.this["clients"].id
  client_id      = keycloak_openid_client.upload.id
  default_scopes = ["roles", "acr", "basic", keycloak_openid_client_scope.locker_api["clients"].name]
}

resource "keycloak_openid_client_default_scopes" "dev_cli" {
  for_each       = keycloak_openid_client.dev_cli
  realm_id       = keycloak_realm.this[each.key].id
  client_id      = each.value.id
  default_scopes = ["roles", "acr", "basic", keycloak_openid_client_scope.locker_api[each.key].name]
}
