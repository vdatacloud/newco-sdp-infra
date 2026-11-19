# Infra plan (I)

Infrastructure for the SDP platform: the local stack, the lab k3s cluster and the Azure environments. Milestones
(`M`), the numbering scheme and cross-plan dependencies live in `newco-sdp-core`'s root `PLAN.md`; the locker's
run-target ladder (R1 to R4) is defined in core's `locker/PLAN.md`. Done phases leave this file for `DONE.md`
(created with the first entry, same template as core's).

Conventions are core's: phase IDs are never reused, sub-slices add a letter, cite core phases by ID ("I3 serves
L2a"). Infra depends on nothing in the app repos except their published images and charts.

| ID | Phase | Serves | Milestone | Status | Exit |
|---|---|---|---|---|---|
| I1 | Dev dependencies in compose (R1) | L0a, L1 | M1 | Planned | `make deps-up` brings up Postgres and Azurite healthy; `make deps-down -v` leaves nothing behind |
| I2 | Compose app profile (R2) | L0b, L3, L4, SL2 | M1 | Planned | Locker and seal worker images run beside Keycloak (two realms), Lowkey Vault, ClamAV and otel-lgtm |
| I3 | Azure dev storage and Key Vault (R3) | L2a | M2 | Planned | Core's contract suite passes against the accounts; a plan from a clean checkout shows no drift |
| I4 | k3s lab cluster on `192.168.1.7` (R4) | L0c, E3a | M2 | Planned | `make dev-up` from a clean host gives a cluster the core e2e suite passes on |
| I5 | Regional stamp, identities, GitHub OIDC (core L2) | L2, E6 | M3 | Planned | Stamp compliant under Azure Policy; a non-main branch can't get an apply token |

## I1: dev dependencies (R1)

- `local/compose.yaml`, profile `deps`: `pgvector/pgvector` with a fixed major version, Azurite with three named
  accounts (landing, client IP, records). Pinned image digests.
- Ports bound to `127.0.0.1` only. No secrets in the file: the Azurite well-known dev key is the only key, and core
  refuses it outside the `dev` profile.
- `Makefile`: `deps-up`, `deps-down`, `deps-logs`.

## I2: compose app profile (R2)

- Profile `app` adds the locker and seal worker by image tag (`LOCKER_IMAGE`, `SEAL_WORKER_IMAGE`, default the local
  `make images` tags from core), so infra holds no app code.
- Keycloak in dev mode with the `lab` and `client` realms, applied by `terraform/modules/keycloak` pointed at
  `localhost`: the same module I5 uses later. Seeded clients for the locker, the seal worker, `locker-upload`
  (device flow) and a test service outside the locker's capability map.
- Lowkey Vault (signing key), ClamAV (signatures cached in a volume), grafana/otel-lgtm with an OTel collector
  config shared with I4.
- `--lite` drops otel-lgtm.

## I3: Azure dev storage and Key Vault (R3)

- Check the active Azure subscription is the SDP one before any plan or apply (the workstation default belongs to
  another organization).
- `terraform/modules/storage-accounts` (the storage subset of the regional stamp, so I5 reuses it): landing,
  client-IP and records accounts; versioning, change feed, version-level immutability support, blob index tags,
  shared-key access disabled, CORS on landing for PUT and OPTIONS from the dev portal origin, Cool and Cold tiers
  only. Network rules allow only the lab's egress address.
- Key Vault (RBAC mode) with the receipt signing key.
- A dev service principal with a certificate credential: Storage Blob Data Owner on the three accounts (needed for
  user delegation keys, holds and tags), Key Vault Crypto User. The certificate stays in the workstation keychain,
  never in this repo or state outputs.
- `terraform/envs/dev-storage/` with remote state in its own storage account; applied from a workstation until I5
  brings GitHub OIDC.
- Per-tenant containers and encryption scopes are not in Terraform: core's provisioner (and `devseed` for now)
  creates them.

## I4: k3s lab cluster (R4)

- Host bootstrap for `192.168.1.7`: Colima profile `sdp-lab` with Kubernetes (6 CPU, 16 GB), the k3s API reachable
  on the LAN, a kubeconfig context `sdp-lab` exported for workstations.
- A registry on the host (`192.168.1.7:5000`) trusted by k3s, so Tilt and `make images` push there.
- `helm/platform`: Traefik ingress, cert-manager with a local CA, Linkerd, the OTel Operator and collectors,
  Kyverno (runner pod label policy arrives with L6).
- Stack charts with `values-local.yaml`: Postgres, Azurite, Keycloak (same Terraform module as I2), Lowkey Vault,
  ClamAV, otel-lgtm. Ollama stays on the host and is added with core H1.
- Hostnames under `*.192.168.1.7.sslip.io`; the local CA's root goes to workstations with mkcert.
- `make dev-up` / `dev-down` drive all of it; seeding calls core's `devseed` job image.
