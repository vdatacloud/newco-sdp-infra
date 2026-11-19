# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Infrastructure for the SDP certification platform: Terraform for the regional stamps, global resources, identities
and Keycloak; the Helm platform chart; and the local stack (k3s or Colima, Keycloak, Azurite, Postgres, Lowkey
Vault, ClamAV, Ollama, otel-lgtm) that `newco-sdp-core`'s integration work runs against. The layout is still to be
set (core plans: locker phase 0, `L2`, `E6`).

## Rules
- **Infra depends on nothing in the app repos** except their published images and charts.
- **Separate owners and approvals:** infra that can open storage to the internet never ships on an app review.
- **Persistence is managed Azure services only.** No stateful workloads in AKS apart from per-pod scratch.
- **Isolation the core architecture depends on is provisioned here:** a container per stage per tenant, per-tenant
  encryption scopes, storage RBAC, legal hold for client IP, locked time-based retention for lab records, and the Cold
  tier (never Archive). Only the locker's identity gets storage and database credentials for tenant data. The
  architecture in `../newco-sdp-core/docs/architecture/` is the source of truth; read the section a change touches.
- **Secrets** come from Key Vault (Lowkey Vault locally), never from code, variables files or state committed here.

## Shared files (edit in core, not here)
`docs/REPOSITORIES.md`, `.claude/skills/github-ci/SKILL.md`, `.github/pull_request_template.md` and
`.github/workflows/repo-policy.yml` are copies of core's; the `repo-policy` workflow's "Shared files" job fails a PR
that differs from core's `main`. Change them in `../newco-sdp-core` and copy them over unchanged.

## Git and CI
Load the `github-ci` skill before any branch, commit, PR or CI work. Commits are signed and signed off (`-s`), and
every change lands through a PR. Never put client data, real tenant names or game titles in this repo.
