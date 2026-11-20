# Infra plan (I)

Infrastructure for the SDP platform: the local stack, the lab k3s cluster and the Azure environments. Milestones
(`M`), the numbering scheme and cross-plan dependencies live in `newco-sdp-core`'s root `PLAN.md`; the locker's
run-target ladder (R1 to R4) is defined in core's `locker/PLAN.md`. Done phases leave this file for `DONE.md`
(created with the first entry, same template as core's).

Conventions are core's: phase IDs are never reused, sub-slices add a letter, cite core phases by ID ("I3 serves
L2a"). Infra depends on nothing in the app repos except their published images and charts.

| ID | Phase | Serves | Milestone | Status | Exit |
|---|---|---|---|---|---|
| I0 | Environment definitions in YAML | — | M1 | Done (#9) | `config/environments/<env>.yaml` is the only place an environment's non-secret values live; `make ENV=<env> <target>` reads it for compose, Terraform and Helm; a schema check fails CI on an unknown or missing key |
| I1 | Dev dependencies in compose (R1) | L0a, L1 | M1 | Planned | `make deps-up` brings up Postgres, Azurite and otel-lgtm healthy; a test span, metric and log sent over OTLP show in Grafana; `make deps-down -v` leaves nothing behind |
| I2a | Compose app profile and OTLP collector (R2) | L0b | M1 | Done (I2a PR) | Core's images run after one-shot migrate bootstrap and up, each with its own env file from core's `make app-env`; `otelcol-<env>` fronts otel-lgtm and owns the OTLP ports; logs, metrics and traces arrive |
| I2b | Keycloak, Lowkey Vault, ClamAV (R2) | I2a | M1 | Done (I2b PR) | Keycloak (two realms via `terraform/modules/keycloak`), Lowkey Vault and ClamAV join the app profile; core L3's smoke gets a token from each realm |
| I3a | Azure dev storage and Key Vault: Terraform written and checked, not applied (R3) | I1 | M2 | Done (plan 2026-11-20: 10 to add, four accounts and the vault with public access off; tflint replaced by `terraform test`) | `validate`, `tflint` and policy checks pass; a plan shows the four accounts with public access off |
| I3c | Private network: VNet, private endpoints, private DNS, Tailscale subnet router | I3a | M2 | Planned | From the Mac and `192.168.1.7`, the account and vault names resolve to private IPs and work; from outside the tailnet they don't resolve to a reachable endpoint |
| I3b | Apply dev storage behind the private network (R3) | I3c, core L4a | M2 | Planned | Core's contract suite passes against the accounts; a plan from a clean checkout shows no drift |
| I3d | Azure Monitor: Terraform written and checked, applied with I3b (R3) | I3a, I3c, core ADR 0009 | M2 | Planned | Per-region Log Analytics workspace, Azure Monitor workspace (managed Prometheus) and Managed Grafana, private access only; the dev collector's Azure pipeline delivers a test span, metric and log to each; the audit log pipeline lands in locked-retention storage, not only Log Analytics |
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

## I0: environment definitions

- One YAML file per environment (`dev`, `lab`, later `azdev`, then per region): suffix, region, ports, image digests,
  storage account roles, network ranges, telemetry endpoints, retention days.
  No secrets: credentials still come from `local/.env.<env>` (generated) or Key Vault.
- A JSON Schema beside them; `make env-check` validates every file (`yq` and `check-jsonschema`, host tools listed in
  `DEVELOPER.md`). Image digests stay in `local/compose.yaml`, where update tooling finds them.
- Consumers read the same file: `scripts/env-render.sh` renders the compose env (`local/.config.<env>`), Terraform uses `yamldecode()`, Helm
  takes it as a values file. The Makefile resolves `ENV` once and passes values down, so targets never hardcode them.
- `make env-diff A=dev B=lab` shows what differs between two environments.

## I1: dev dependencies (R1)

- `local/compose.yaml`, profile `deps`: `pgvector/pgvector` with a fixed major version, Azurite with four named
  accounts (landing, client IP, records, platform), matching architecture §02. `grafana/otel-lgtm` (collector, Prometheus, Loki, Tempo, Grafana) so services export OTLP from core L0a. Pinned image digests.
- Ports bound to `127.0.0.1` only (Postgres 55432, Blob 10100, Grafana 13000, OTLP gRPC 14317 and HTTP 14318). Credentials are generated per environment into
  `local/.env.<env>` (gitignored) by `scripts/dev-env.sh`; core refuses shared-key access outside the `dev` profile.
- `Makefile`: `deps-up`, `deps-down`, `deps-logs`.

## I2b: identity, keys and scanning (R2), done

- `keycloak-<env>` (26.4.7, dev mode, `127.0.0.1:18180`), `lowkey-vault-<env>` (`127.0.0.1:18443`, vault
  `sdp-<env>`) and `clamav-<env>` (clamd on 3310, network-internal, signatures in a volume), all pinned by digest.
- `terraform/modules/keycloak` (reused by I5): realms `lab` and `clients`, §04's realm roles, a `locker-api`
  audience scope attached to every client, `org` claim from a user attribute. Service clients `locker`,
  `seal-worker` and `sdp-probe` (outside the capability map, for L3's negative test); `locker-upload` device flow.
- `terraform/envs/dev` adds dev-only `dev-cli` password clients and three fake users (`dev-tester`, `dev-admin`,
  `dev-client1` with `org` = devseed tenant1). Secrets are sensitive outputs; state is in `local/` (gitignored).
  `make idp-apply` (idempotent, no drift on re-apply), `make idp-issuers`.
- `scripts/dev-env.sh` now appends keys missing from an existing `local/.env.<env>` without touching existing
  values (adds `KEYCLOAK_ADMIN_PASSWORD`).
- Deviations: realm `clients`, not `client` (matches §04). `org` is a declared user-profile attribute that only
  admins may view or edit (a user who sets their own `org` gets 400), not Keycloak Organizations. The three
  services run in the `deps` profile, not `app`, because Terraform needs Keycloak before the app starts.
  Keycloak and vault ports are compose defaults, not yet in `config/environments/*.yaml`.

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
- As written (2026-11-20): environment `azdev` (`config/environments/azdev.yaml`, target `azure`, eastus2). Names
  follow `<client>-<project>-<type>-<instance>-<stage>` (`newco-sdp-rg-1-dev`, `newco-sdp-kv-1-dev`); storage
  accounts drop the hyphens and use the role's `short` (`newcosdplnd1dev`, `newcosdpcip1dev`, `newcosdprec1dev`,
  `newcosdpplat1dev`). Policy checks are `terraform test` with a mocked provider (`make azure-check`); tflint is
  not yet a host tool. Terraform signs in as `sp-tf-workload-sdp-dev` with its certificate; `make azure-plan`
  reads the certificate password from the keychain item of that name. The workload principal's role
  assignments apply only when `workload_principal_id` is set. The receipt key `receipts` (P-256) and the
  platform containers need data-plane or private access, so they are created at I3b.
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

### I3d: Azure Monitor, written and checked

- Per ADR 0009 in core: services only speak OTLP to a collector; the collector routes. Locally that is otel-lgtm;
  in Azure the collector exports metrics to an Azure Monitor workspace (managed Prometheus), traces and operational
  logs to Application Insights and a Log Analytics workspace, and Managed Grafana reads both.
- One Log Analytics workspace per region (data residency); short operational retention.
- Audit logs take a second collector pipeline to locked-retention storage in the platform account, so audit evidence
  never depends on Log Analytics retention alone.
- Private access only (Azure Monitor Private Link Scope through I3c); written now, applied with I3b.

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
