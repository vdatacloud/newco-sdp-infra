# Dev-only test users, linked to devseed principals by the issuer subject in core's L3 seed.
# Passwords are generated and exposed only as sensitive outputs.

locals {
  dev_users = var.dev_users_enabled ? var.dev_users : {}
}

resource "random_password" "dev_user" {
  for_each = local.dev_users
  length   = 32
  special  = false
}

resource "keycloak_user" "dev" {
  depends_on = [keycloak_realm_user_profile.clients]
  for_each   = local.dev_users
  realm_id   = keycloak_realm.this[each.value.realm].id
  username   = each.key
  enabled    = true
  # Fake profile fields Keycloak 26 requires before it issues tokens; example.invalid never resolves.
  first_name     = "Dev"
  last_name      = each.key
  email          = "${each.key}@example.invalid"
  email_verified = true
  attributes     = each.value.org == null ? {} : { org = each.value.org }
  initial_password {
    value     = random_password.dev_user[each.key].result
    temporary = false
  }
}

resource "keycloak_user_roles" "dev" {
  for_each   = local.dev_users
  realm_id   = keycloak_realm.this[each.value.realm].id
  user_id    = keycloak_user.dev[each.key].id
  role_ids   = [for r in each.value.roles : keycloak_role.realm["${each.value.realm}/${r}"].id]
  exhaustive = false
}
