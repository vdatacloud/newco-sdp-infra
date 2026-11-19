SHELL := /bin/bash
# Local SDP stack. ENV selects config/environments/$(ENV).yaml (default dev) and the namespace:
# project sdp-$(ENV), containers <svc>-$(ENV). Non-secret values come only from that YAML file.
ENV ?= dev
ENV_YAML := config/environments/$(ENV).yaml
CONFIG_FILE := local/.config.$(ENV)
ENV_FILE := local/.env.$(ENV)
COMPOSE := docker compose -f local/compose.yaml --env-file $(ENV_FILE) --env-file $(CONFIG_FILE) --profile deps
CHECK_JSONSCHEMA := check-jsonschema

.PHONY: help env-check env-diff env-render deps-env deps-up deps-down deps-reset deps-ps deps-logs deps-info

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

env-check: ## Check host tools (DEVELOPER.md) and validate every config/environments/*.yaml
	@for t in docker yq check-jsonschema openssl; do command -v $$t >/dev/null || { echo "missing $$t: see DEVELOPER.md"; exit 1; }; done
	@for f in config/environments/*.yaml; do \
	  yq -o=json "$$f" > "local/.check.$$(basename $$f .yaml).json" || exit 1; \
	  $(CHECK_JSONSCHEMA) --schemafile config/environments/schema.json "local/.check.$$(basename $$f .yaml).json" || exit 1; \
	done; rm -f local/.check.*.json

env-diff: ## Show differences between two environments: make env-diff A=dev B=lab
	@diff <(yq -P 'sort_keys(..)' config/environments/$(A).yaml) \
	      <(yq -P 'sort_keys(..)' config/environments/$(B).yaml) || true

env-render: ## Render $(ENV_YAML) into $(CONFIG_FILE) for compose (non-secret, gitignored)
	@test "$$(yq '.target' $(ENV_YAML))" = compose || { echo "$(ENV) is not a compose environment"; exit 1; }
	@scripts/env-render.sh $(ENV)

deps-env: env-render ## Generate local/.env.$(ENV) once (dev-only secrets, gitignored)
	@scripts/dev-env.sh $(ENV)

deps-up: deps-env ## Start Postgres (pgvector), Azurite and otel-lgtm for sdp-$(ENV) and wait until healthy
	@$(COMPOSE) up -d --wait

deps-down: env-render ## Stop sdp-$(ENV), keeping its volumes
	@$(COMPOSE) down

deps-reset: env-render ## Stop sdp-$(ENV) and delete its volumes (data is lost)
	@$(COMPOSE) down -v

deps-ps: env-render ## Show sdp-$(ENV) containers
	@$(COMPOSE) ps

deps-logs: env-render ## Follow sdp-$(ENV) logs
	@$(COMPOSE) logs -f

deps-info: env-render ## Print endpoints and account names for sdp-$(ENV) (never prints passwords or keys)
	@get() { sed -n "s/^$$1=//p" $(CONFIG_FILE) | tr -d "'"; }; \
	echo "postgres  127.0.0.1:$$(get SDP_PG_PORT) db=$$(get POSTGRES_DB) user=$$(get POSTGRES_USER) (password in $(ENV_FILE))"; \
	for p in $$(yq '.storage.accounts[].prefix' $(ENV_YAML)); do echo "blob      http://127.0.0.1:$$(get SDP_BLOB_PORT)/$${p}$(ENV)"; done; \
	echo "grafana   http://127.0.0.1:$$(get SDP_GRAFANA_PORT) (local only, default login)"; \
	echo "otlp      grpc 127.0.0.1:$$(get SDP_OTLP_GRPC_PORT)  http http://127.0.0.1:$$(get SDP_OTLP_HTTP_PORT)"
