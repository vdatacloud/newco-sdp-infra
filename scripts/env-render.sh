#!/bin/sh
# Render config/environments/<env>.yaml into local/.config.<env> (compose env-file, non-secret, gitignored).
# Usage: scripts/env-render.sh <env>
set -eu
env=${1:?env}
root=$(cd "$(dirname "$0")/.." && pwd)
src="config/environments/$env.yaml"
[ -f "$root/$src" ] || { echo "no $src" >&2; exit 1; }
cd "$root"
yq -o=shell '
  {"SDP_ENV": .env, "SDP_PG_PORT": .ports.postgres, "SDP_BLOB_PORT": .ports.blob,
   "SDP_GRAFANA_PORT": .ports.grafana, "SDP_OTLP_GRPC_PORT": .ports.otlp_grpc,
   "SDP_OTLP_HTTP_PORT": .ports.otlp_http, "POSTGRES_DB": .postgres.db, "POSTGRES_USER": .postgres.admin_user}
  | with_entries(select(.value != null))' "$src" > "$root/local/.config.$env"
