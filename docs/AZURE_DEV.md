# Azure dev stamp (R3): setup and operations

How the Azure dev environment (`azdev`, infra I3a to I3c) was built, and every snag hit on the way, so it can be
rebuilt from scratch. Non-secret values live in `config/environments/azdev.yaml`; secrets live only in the
workstation keychain. Nothing here is client data.

## What it is

| Piece | Name | Notes |
|---|---|---|
| Resource group | `newco-sdp-rg-1-dev` | East US 2 |
| Storage accounts | `newcosdplnd1dev`, `newcosdpcip1dev`, `newcosdprec1dev`, `newcosdpplat1dev` | landing, client IP, records, platform; private only, Entra only, versioning, change feed, version-level WORM support |
| Key Vault | `newco-sdp-kv-1-dev` | RBAC, purge protection, private only; key `receipts` (EC P-256) |
| VNet | `newco-sdp-vnet-1-dev` `10.42.0.0/16` | `snet-pe` 10.42.1.0/24 (endpoints), `snet-router` 10.42.2.0/27 |
| Private endpoints | `newco-sdp-pe-1-dev-*` | vault 10.42.1.4, platform .5, client IP .6, records .7, landing .8 |
| Router | `newco-sdp-vm-1-dev` 10.42.2.4 | D2s_v5, zone 2, no public IP; Tailscale subnet router plus dnsmasq to Azure DNS; stops daily 19:00 Eastern |
| NAT gateway | `newco-sdp-nat-1-dev` + `newco-sdp-pip-1-dev` | outbound for the router only |

Naming: `<client>-<project>-<type>-<instance>-<stage>`. Storage account names cannot hold hyphens, so they are
`<client><project><role><instance><stage>` with the role's `short` from the environment file.

## Identities

| Identity | Used by | Rights |
|---|---|---|
| `sp-tf-workload-sdp-dev` (certificate) | Terraform | Contributor on the subscription; on the resource group, Key Vault Crypto Officer and Role Based Access Control Administrator **restricted** to assigning Storage Blob Data Owner and Key Vault Crypto User only |
| `sp-sdp-locker-dev` (certificate) | locker and seal worker (core L2a) | Storage Blob Data Owner and SDP Encryption Scope Writer (custom) on the four accounts, Key Vault Crypto User and Secrets Officer on the vault (assigned by Terraform from `azure.workload_principal_id`) |
| purge worker principal (not created yet) | purge worker (core TD-14) | Storage Blob Data Owner and SDP Encryption Scope Writer on the three tenant accounts, Key Vault Crypto User on the vault (assigned by Terraform from `azure.purge_principal_id`; written and plan-tested, never applied) |

Both sign in with certificates; neither has a client secret. Keep the `.pfx`/`.pem` files outside every repo,
mode 600.

## Prerequisites (one-off, as a subscription owner)

1. **Use the right subscription.** The workstation default belongs to another organisation and `az login` can
   switch back to it. `make azure-plan` and `azure-apply` refuse to run unless the active subscription is the one
   in `azdev.yaml`:
   `az account set --subscription <azure.subscription_id>`
2. **Register resource providers.** The Terraform principal cannot register them, and the provider is set to
   `resource_provider_registrations = "none"` so Terraform never enables services we did not choose:
   ```
   for n in Microsoft.Storage Microsoft.KeyVault Microsoft.Network Microsoft.Compute Microsoft.DevTestLab; do
     az provider register -n $n --subscription <sub>
   done
   ```
   `Microsoft.DevTestLab` is only for the VM auto-shutdown schedule. Wait until each shows `Registered`.
3. **Grant the Terraform principal Contributor** on the subscription.
4. **Keychain items** (from a normal terminal, not Claude Code's `!`, which has no TTY and stores an empty value):
   - `security add-generic-password -s sp-tf-workload-sdp-dev -a "$USER" -w` with the **`.pfx` password**
     (not a client secret). Check it with
     `openssl pkcs12 -in <pfx> -noout -passin "pass:$(security find-generic-password -s sp-tf-workload-sdp-dev -w)"`.
   - `security add-generic-password -s tailscale-sdp-dev -a "$USER" -w` with a Tailscale auth key: single use,
     pre-approved, expiring within a day. It lands in VM custom data and local state, so it must be dead after the
     router's first boot. Generate it just before the `net` stage.
5. **Tailscale on the workstation** (the macOS app; `tailscale` is not on the PATH unless CLI integration is
   enabled in the app). Settings: Use Tailscale DNS settings and Use Tailscale subnets both on.

## Management group policy

The `newco-sdp-dev` management group enforces, and the Terraform complies with:

- `Owner`, `Project` and `Environment` tags required on resource groups (deny) and inherited onto resources
  (modify). Terraform sets all three on every resource, or the inheritance shows as drift on every plan.
- Locations East US and East US 2 only; storage SKUs LRS or ZRS; HTTPS only; no anonymous blob access.
- VM sizes B1s, B2s, B2ms, B4ms, D2s_v5, D4s_v5 only.

## Build

```
make azure-check              # fmt, validate, terraform test with a mocked provider (no Azure needed)
make azure-plan               # read-only plan as the Terraform principal
make azure-apply STAGE=rg     # 1: the resource group only
#   then grant the two resource-group roles below
make azure-apply STAGE=net    # 2: storage, vault, network, endpoints, router, role assignments
#   then the Tailscale console steps below
make azure-apply STAGE=key    # 3: the receipts key, over the tailnet (data plane)
make azure-plan               # must say "No changes"
```

Add `APPROVE=1` to skip the confirmation. Terraform's "Resource targeting is in effect" warnings during stages
are expected. State is local and gitignored (`local/terraform-azdev-storage.tfstate`): a single developer can
wipe and rebuild, so there is no remote state account yet.

**Resource-group roles (after stage 1).** zsh treats `!` in double quotes as history expansion, so load the
condition through a quoted heredoc:

```
SP=<azure.terraform_client_id>
RG=/subscriptions/<sub>/resourceGroups/newco-sdp-rg-1-dev
az role assignment create --assignee $SP --role "Key Vault Crypto Officer" --scope $RG
COND=$(cat <<'EOF'
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 12338af0-0e69-4776-bea7-57ae8d297424}))
EOF
)
az role assignment create --assignee $SP --role "Role Based Access Control Administrator" --scope $RG \
  --condition-version 2.0 --condition "$COND"
```

The two GUIDs are Storage Blob Data Owner and Key Vault Crypto User.

**Encryption scope and secrets roles (I3e).** Per-tenant encryption scopes are created by the locker at tenant onboarding,
which needs `encryptionScopes/write` on the accounts. No built-in role is that narrow, and Contributor cannot
create role definitions, so an owner creates the custom role once and widens the Terraform principal's condition
to include it, then reapplies:

```
az role definition create --role-definition @config/azure-roles/sdp-encryption-scope-writer.json
ROLE=$(az role definition list --custom-role-only --name "SDP Encryption Scope Writer" --query '[0].name' -o tsv)
az role assignment list --assignee $SP --scope $RG --role "Role Based Access Control Administrator" --query '[0].id' -o tsv \
  | xargs az role assignment delete --ids
COND=$(cat <<EOF
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 12338af0-0e69-4776-bea7-57ae8d297424, b86a8fe4-44ce-4948-aee5-eccb2c155cd7, $ROLE}))
EOF
)
az role assignment create --assignee $SP --role "Role Based Access Control Administrator" --scope $RG \
  --condition-version 2.0 --condition "$COND"
make azure-apply STAGE=net
```

`b86a8fe4-…` is Key Vault Secrets Officer: tenant name keys are vault secrets (core TD-12) that devseed creates
and the locker reads. This heredoc is unquoted so `$ROLE` expands; zsh does not history-expand inside a heredoc. A new custom role can
take a few minutes to become visible; rerun the apply if it says the role was not found. A scope `write` can also
disable a scope (the tenant's data becomes unreadable), so on AKS this role goes to a separate onboarding identity
with a federated credential, never to the locker API's identity.

**Tailscale console (after stage 2).** The router appears under Machines once it boots.

1. Machines → `newco-sdp-vm-1-dev` → Edit route settings → approve `10.42.0.0/16`.
2. DNS → Nameservers → Add nameserver → Custom `10.42.2.4`, Restrict to domain `blob.core.windows.net`; again for
   `vault.azure.net`.
3. Optionally revoke the (already used) auth key.

## Check

```
dig +short newco-sdp-kv-1-dev.vault.azure.net        # 10.42.1.4 via *.privatelink.vaultcore.azure.net
dig +short newcosdplnd1dev.blob.core.windows.net     # 10.42.1.8
```

Off the tailnet the same names resolve to public addresses that refuse every request (public access disabled).
The first lookup after the router starts can time out while dnsmasq warms up; retry.

## Snags and their fixes

| Symptom | Cause | Fix (in the code now) |
|---|---|---|
| `Terraform does not have the necessary permissions to register Resource Providers` | azurerm registers every provider by default | `resource_provider_registrations = "none"`; an owner registers the five providers once |
| `RequestDisallowedByPolicy` on the resource group | management group requires `Owner`, `Project`, `Environment` tags | tags set from `azdev.yaml` on every resource |
| `MissingSubscriptionRegistration` for Storage, KeyVault, Network, Compute, DevTestLab | providers not registered | register them (above) |
| `KeyBasedAuthenticationNotPermitted` after creating the storage accounts | azurerm polls the blob endpoint with a shared key | `storage_use_azuread = true` and `features.storage.data_plane_available = false`; the half-created accounts were untainted rather than rebuilt |
| `SkuNotAvailable` for B1s, then D2s_v5 | B-series is not offered to the subscription in East US or East US 2; D2s_v5 had capacity only in zone 2 | router is D2s_v5 pinned to zone 2; ask Azure support for B-series to go back to B1s |
| `ForbiddenByConnection` creating the key although `dig` showed 10.42.1.4 | the macOS system resolver (used by Terraform by default) returned the vault's public address; Go's resolver asks 100.100.100.100 and follows split DNS | make targets run Terraform with `GODEBUG=netdns=go`; `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` may help other tools |
| zsh `parse error near '}'` on the role condition | `!` history expansion inside double quotes | quoted heredoc |
| Keychain password stored empty | `security ... -w` run through `!`, which has no TTY | run it in a normal terminal; check with `security find-generic-password -s <item> -w \| wc -c` |
| `az` suddenly on another subscription | `az login` resets the default | `az account set`; the make targets check it |

## Operating it

- `make azure-router-start` / `make azure-router-stop` (deallocate). The router also stops itself daily at 19:00
  Eastern. Private endpoints and NAT bill whether or not it runs.
- Rough cost: about $150 a month all on, about $100 with the router on working hours only, a few dollars with the
  network removed (storage and vault kept). Private endpoints (~$37) and NAT (~$37 with its IP) dominate.
- The Key Vault has purge protection: deleting it leaves it soft-deleted for 90 days, and recreating the same name
  recovers it (provider `recover_soft_deleted_key_vaults = true`), `receipts` key included.
- **Park it** when no work needs Azure: `make azure-park` destroys only `module.network` (private endpoints, NAT and
  its IP, router VM, VNet, private DNS); nothing depends on it, so storage accounts, the vault, the receipts key,
  encryption scopes and role assignments stay. Storage and vault then have no reachable endpoint at all (public
  access stays off) and cost a few dollars a month. A plain `make azure-plan` shows the network to add while
  parked; that is expected. `make azure-unpark` (the net stage) brings it back, then repeat the Tailscale console
  steps with a fresh single-use auth key in the keychain (the router is a new machine).
  After parking, in the Tailscale console remove the two `10.42.2.4` split-DNS nameservers (`blob.core.windows.net`,
  `vault.azure.net`), or every blob and vault lookup on the tailnet, any organisation's, goes to a dead resolver;
  and remove the `newco-sdp-vm-1-dev` machine.
- If Tailscale ever lapses nothing opens up: there is no inbound path. Alternatives are an Azure VPN Gateway
  (point-to-site, I5) or a temporary IP allowlist on the accounts and vault.
