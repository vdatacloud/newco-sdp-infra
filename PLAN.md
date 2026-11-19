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
| I3a | Azure dev storage and Key Vault: Terraform written and checked, not applied (R3) | I1 | M2 | Planned | `validate`, `tflint` and policy checks pass; a plan shows the four accounts with public access off |
| I3c | Private network: VNet, private endpoints, private DNS, Tailscale subnet router | I3a | M2 | Planned | From the Mac and `192.168.1.7`, the account and vault names resolve to private IPs and work; from outside the tailnet they don't resolve to a reachable endpoint |
| I3b | Apply dev storage behind the private network (R3) | I3c, core L4a | M2 | Planned | Core's contract suite passes against the accounts; a plan from a clean checkout shows no drift |
| I4 | k3s lab cluster on `192.168.1.7` (R4) | L0c, E3a | M2 | Planned | `make dev-up` from a clean host gives a cluster the core e2e suite passes on |
| I5 | Regional stamp, identities, GitHub OIDC (core L2) | L2, E6 | M3 | Planned | Stamp compliant under Azure Policy; a non-main branch can't get an apply token |

## Naming and isolation (all phases)

Every Docker and Kubernetes resource lives in its own namespace and carries the environment as a suffix, so SDP
never shares or collides with other projects on the same host and an environment tears down cleanly:

- Compose: project `sdp-dev` (`name:` in the file), containers `<service>-dev` (`postgres-dev`, `azurite-dev`,
  `locker-dev`), network `sdp-dev-net`, volumes `sdp-dev-<service>`. A second stack uses another suffix
  (`sdp-test`, `-test`).
- Images built locally: `sdp/<service>:dev` (or `:dev-<git sha>`), never `latest`.
- k3s: namespaces `sdp-dev` (services) and `sdp-dev-platform` (stack charts); nothing in `default`. The kube
  context is `sdp-lab`.
- `make deps-down` / `dev-down` remove only resources with the stack's project label or namespace.

## I1: dev dependencies (R1)

- `local/compose.yaml`, profile `deps`: `pgvector/pgvector` with a fixed major version, Azurite with four named
  accounts (landing, client IP, records, platform), matching architecture §02. Pinned image digests.
- Ports bound to `127.0.0.1` only (Postgres 55432, Blob 10100). Credentials are generated per environment into
  `local/.env.<env>` (gitignored) by `scripts/dev-env.sh`; core refuses shared-key access outside the `dev` profile.
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

Three slices: write and check the Terraform alongside I1 (I3a); build the private network (I3c); apply only once
both exist and core needs R3 (I3b). Nothing is applied with public network access on.

- Check the active Azure subscription is the SDP one before any plan or apply (the workstation default belongs to
  another organization).

### I3a: storage and Key Vault, written and checked

- `terraform/modules/storage-accounts` (the storage subset of the regional stamp, so I5 reuses it): landing,
  client-IP, records and a dev platform account (global and replicated from I5 on). Versioning, change feed,
  version-level immutability support, blob index tags, shared-key access disabled, **public network access
  disabled**, Cool and Cold tiers only (never Archive). CORS on landing for PUT and OPTIONS from the dev portal
  origin, for when browser upload is tested.
- Key Vault (RBAC mode, public access disabled) with the receipt signing key.
- A dev service principal with a certificate credential: Storage Blob Data Owner on the four accounts (needed for
  user delegation keys, holds and tags), Key Vault Crypto User. The certificate stays in the workstation keychain,
  never in this repo or state outputs.
- The account roles and names are declared once and shared with I1's Azurite setup, so local and Azure cannot
  drift.
- `terraform/envs/dev-storage/`. Checks without Azure: `terraform validate`, `tflint`, and policy checks for the
  §02 rules (shared key off, public access off, versioning on, no Archive tier).
- Per-tenant containers and encryption scopes are not in Terraform: core's provisioner (and `devseed` for now)
  creates them. Terraform creates only the platform account's containers.

### I3c: private network

- `terraform/modules/dev-network`: VNet `vnet-sdp-dev` with a private-endpoint subnet and a router subnet; NSGs
  deny inbound from the internet.
- Private endpoints for the four accounts (blob) and Key Vault. Private DNS zones
  `privatelink.blob.core.windows.net` and `privatelink.vaultcore.azure.net` linked to the VNet.
- Subnet router: one small Linux VM (`vm-sdp-dev-router`, B-series) with no public IP. Cloud-init installs
  Tailscale, advertises the private subnet and enables IP forwarding. The Tailscale auth key comes from the
  workstation keychain or Key Vault at apply time and is never committed or written to state outputs. The VM's
  outbound internet access is NAT only.
- Tailnet: the Mac and `192.168.1.7` join. Split DNS sends `blob.core.windows.net` and `vault.azure.net` to Azure's
  resolver through the router, so SAS URLs keep their real hostnames and resolve privately. k3s pods reach it
  through the host.
- Sign-in to Entra and Azure Resource Manager stays public, so `plan` and `apply` work from anywhere. Data-plane
  steps (platform containers, the contract suite) run from a tailnet machine.
- Terraform state: its own storage account, reachable from the workstation by IP allowlist while bootstrapping,
  then moved behind a private endpoint once I3c exists.
- Later: when I5 builds the hub network, an Azure VPN Gateway (point-to-site) can replace the router.

### I3b: apply

- Apply I3c, then I3a, from a tailnet machine; run core's R3 contract suite (L2a).
- Browser-upload tests on R3 (portal, L5) will need landing given a public endpoint with CORS and an IP allowlist,
  as in production, where landing is public and SAS-only. That change gets its own PR.

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
