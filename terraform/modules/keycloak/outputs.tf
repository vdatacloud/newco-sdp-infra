output "issuers" {
  description = "Issuer path per realm, relative to the Keycloak base URL."
  value       = { for k, r in keycloak_realm.this : k => "/realms/${r.realm}" }
}

output "service_client_secrets" {
  description = "Client secrets for the service clients."
  value       = { for k, c in keycloak_openid_client.service : k => c.client_secret }
  sensitive   = true
}

output "dev_user_passwords" {
  description = "Dev user passwords."
  value       = { for k, p in random_password.dev_user : k => p.result }
  sensitive   = true
}
