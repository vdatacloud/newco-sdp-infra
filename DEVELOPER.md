# Developer setup

Every tool this repo's Makefile, scripts and Terraform call on the host. Install with Homebrew (macOS). When a
target needs a new tool, add it here in the same PR. Versions are the minimum tested; container images are pinned by
digest in `local/compose.yaml`, not listed here.

## Required now

| Tool | Brew | Min version | Used by |
|---|---|---|---|
| Docker Engine and Compose v2 | Docker Desktop, or `colima` + `docker` + `docker-compose` | 29.x, Compose 2.x | `make deps-*` (local stack R1/R2) |
| GNU Make | (macOS ships 3.81) | 3.81 | All targets; recipes run in bash |
| yq (mikefarah) | `yq` | 4.54 | Reads `config/environments/*.yaml` (`env-*`, `deps-*`, scripts) |
| check-jsonschema | `check-jsonschema` | 0.39 | `make env-check` |
| OpenSSL | (macOS) or `openssl` | 3.x | `scripts/dev-env.sh` generates dev-only secrets |
| GitHub CLI | `gh` | 2.100 | PRs, CI checks (`github-ci` skill) |

```sh
brew install yq check-jsonschema gh
```

## Required later (by phase)

| Tool | Brew | Phase | Used by |
|---|---|---|---|
| Terraform | `hashicorp/tap/terraform` | I3a | `terraform/` validate and plan |
| TFLint | `tflint` | I3a | Terraform lint |
| Azure CLI | `azure-cli` | I3a, I3b | Auth for plan and apply; check the active subscription first |
| Tailscale | `tailscale` (or the app) | I3c | Private access to Azure endpoints and the lab cluster |
| kubectl | `kubectl` | I4 | k3s lab cluster (`192.168.1.7`, context `sdp-lab`) |
| Helm | `helm` | I4 | Platform charts on k3s |

## Check

```sh
make env-check      # tools present and every environment file valid
make deps-up        # local stack healthy
```
