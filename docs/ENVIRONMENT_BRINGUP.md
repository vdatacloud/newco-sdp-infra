# Environment bring-up: dev to staging to production

The order in which an SDP Azure environment (a "stamp") is built and proven, and what must change as it moves
from the dev stamp toward staging and production. `AZURE_DEV.md` holds the exact commands for the dev stamp; this
file is the plan that stays true for every stamp. Non-secret values live in `config/environments/<env>.yaml`;
secrets never live in a repo. Nothing here names a client.

## Phases

Each phase ends with a gate. Do not start the next phase until its gate passes; record the result in the core
`DONE.md` entry for the phase that needed it.

| # | Phase | Who | Steps | Gate |
|---|---|---|---|---|
| 0 | Subscription | Owner | Subscription and management group with the SDP policies (tags, locations, SKUs, HTTPS, no anonymous blobs); register the resource providers Terraform may not register | `az account show` names the environment's subscription; providers show `Registered` |
| 1 | Terraform identity | Owner | A principal for Terraform: Contributor on the subscription. On the resource group, Key Vault Crypto Officer and Role Based Access Control Administrator **with a condition** naming the only roles it may assign (below) | `make azure-check` passes; `make azure-plan` reads the subscription |
| 2 | Custom roles | Owner | Create `SDP Encryption Scope Writer` and `SDP Evidence Writer` from `config/azure-roles/` (replace `{RG}` with the resource group ID), then widen the Terraform identity's condition to list both | `az role definition list --custom-role-only` shows both; the condition lists both IDs |
| 3 | Workload identities | Owner | One identity per role, never shared across roles: the locker workload, the purge worker, later a separate onboarding identity and the seal worker. Put each object ID in the environment file (`workload_principal_id`, `purge_principal_id`, ...) | `az ad sp show` returns each ID; the environment file validates against `schema.json` |
| 4 | Resource group | Terraform | `make azure-apply STAGE=rg` | The group exists with the required tags |
| 5 | Storage, vault, network | Terraform | `make azure-apply STAGE=net`: four accounts (landing, client IP, records, platform), the vault, private endpoints and DNS, the private access path | `make azure-plan` shows only the data-plane key left |
| 6 | Private access | Operator | Dev: the Tailscale router and split DNS (`AZURE_DEV.md`). Staging and production: AKS in the VNet, no workstation path to the data plane | Account and vault names resolve to private addresses from where the services run |
| 7 | Keys and role assignments | Terraform | `make azure-apply STAGE=key`: the receipts key and every data role, with `evidence_writer_role: true` | `make azure-plan` says "No changes" |
| 8 | Contract proof | Core | The storage contract suite as each identity (below) | Every case passes; nothing is skipped except by design |
| 9 | Service proof | Core | Run the locker, seal worker and purge worker against the stamp; purge, offboarding, collapse and tiering on real accounts | The reconnect plan's rows pass, including certification after the soft-delete window |

## Roles each identity holds

The rule: only the purge principal can destroy sealed evidence, and no identity holds Owner on the client IP or
records accounts. Storage enforces this, independent of locker authorization and RLS.

| Identity | Landing | Client IP, records | Platform | Vault |
|---|---|---|---|---|
| Locker workload (locker, seal worker) | Blob Data Owner (the seal path deletes landing copies) | SDP Evidence Writer (no delete), Scope Writer | Blob Data Owner | Crypto User; Secrets Officer on dev only |
| Purge worker | Blob Data Owner, Scope Writer | Blob Data Owner, Scope Writer | none | Crypto User |
| Onboarding (staging on) | none | Scope Writer | none | Secrets Officer |
| Terraform | none (control plane only) | none | none | Crypto Officer |

Role IDs the Terraform condition must list: Storage Blob Data Owner `b7e6dc6d-…`, Key Vault Crypto User
`12338af0-…`, Key Vault Secrets Officer `b86a8fe4-…`, and the two custom roles' IDs for that subscription (look
them up by name; custom role IDs differ per subscription).

## Proof commands (run from core)

| Gate | Command | Identity |
|---|---|---|
| Storage contract | `make azure-contract AZ_NODELETE=1` | locker workload |
| Destroy contract | `make azure-contract-purge AZ_PURGE_CLIENT=<app id>` | purge worker |
| Purge, offboarding, collapse | `make azdev-purge-test AZ_PURGE_CLIENT=<app id>` | purge worker |
| Tiering with protections | `make azdev-tiering-test` | locker workload |
| Certification | rerun the purge worker after `verify_after` (8 days) | purge worker |

These targets name the dev stamp today; a new stamp needs its own variables (`AZ_ACCOUNTS`, `AZ_RG`, the client
IDs) passed in, not new targets.

## From dev to staging and production

| Concern | Dev stamp (today) | Staging and production |
|---|---|---|
| Identity type | Service principals with certificates in the workstation keychain | Managed identities with workload identity federation on AKS; no certificates or secrets to hold |
| Identity split | Locker and seal worker share one identity | Separate locker, seal worker, purge worker and onboarding identities; the locker API never holds Scope Writer (it can disable a scope) |
| Terraform state | Local file, one developer | Remote state in a locked storage account, applies from CI with approval |
| Who applies | The developer | A pipeline, with a second person approving any role change |
| Private access | Tailscale router, stopped nightly, parked when idle | AKS in the VNet; no workstation route to the data plane |
| Secrets Officer | The workload (devseed creates tenant name keys) | Onboarding only; the locker reads with Secrets User |
| Custom roles | Created by hand by the owner | Created by the owner once per subscription, definitions from `config/azure-roles/`, reviewed like code |
| Soft delete and `verify_after` | 7 days and 8 days | The same unless an ADR changes them; certification always waits out soft delete |
| Regions | One (East US 2) | One stamp per jurisdiction; client IP never leaves its stamp |
| Cost | Park the network when idle (`make azure-park`) | Always on; no parking |

## Open before staging

- The workload identity federation design for AKS and how each service gets its own identity.
- Remote Terraform state: account, locking and who may read it.
- The CI apply pipeline and its approval rule for role changes.
- Whether the seal worker gets its own identity, so the locker API can lose landing Owner too.
- An approver path for purges with MFA in each environment's identity provider.
