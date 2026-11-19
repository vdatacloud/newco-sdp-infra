# newco-sdp-infra
Terraform, Helm, and the local k3s, Keycloak and Azurite setup.

How the SDP repos fit together: [`docs/REPOSITORIES.md`](docs/REPOSITORIES.md), a checked copy of the map in `newco-sdp-core`.

## Local stack

Postgres 17 with pgvector, otel-lgtm (Grafana on 13000, OTLP on 14317/14318) and Azurite with the four storage accounts (landing, client IP, records, platform) from
`config/environments/<env>.yaml`, namespaced by environment (`ENV`, default `dev`). Tools: see `DEVELOPER.md`.

```sh
make env-check    # validate config/environments/*.yaml
make env-diff A=dev B=lab
make deps-up      # renders local/.config.dev, generates local/.env.dev secrets on first run, starts the stack
make deps-info    # endpoints and account names (no secrets)
make deps-down    # stop, keep data;  make deps-reset deletes the sdp-dev volumes
```

Ports bind to 127.0.0.1 and come from the environment file (`ports:`). Secrets are never in it: they are generated per environment into `local/.env.<env>` (gitignored, mode 600) and are dev-only.
