# newco-sdp-infra
Terraform, Helm, and the local k3s, Keycloak and Azurite setup.

How the SDP repos fit together: [`docs/REPOSITORIES.md`](docs/REPOSITORIES.md), a checked copy of the map in `newco-sdp-core`.

## Local stack

Postgres 17 with pgvector and Azurite with the four storage accounts (landing, client IP, records, platform) from
`config/storage-accounts.json`, namespaced by environment (`ENV`, default `dev`):

```sh
make deps-up      # generates local/.env.dev on first run, starts postgres-dev and azurite-dev, waits for health
make deps-info    # endpoints and account names (no secrets)
make deps-down    # stop, keep data;  make deps-reset deletes the sdp-dev volumes
```

Ports bind to 127.0.0.1: Postgres on 55432, Blob on 10100 (`SDP_PG_PORT`, `SDP_BLOB_PORT` override). Credentials
are generated per environment into `local/.env.<env>` (gitignored, mode 600) and are dev-only.
