# Local SDP stack. ENV selects the namespace (default dev): project sdp-$(ENV), containers <svc>-$(ENV).
ENV ?= dev
ENV_FILE := local/.env.$(ENV)
COMPOSE := docker compose -f local/compose.yaml --env-file $(ENV_FILE) --profile deps

.PHONY: help deps-env deps-up deps-down deps-reset deps-ps deps-logs deps-info

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

deps-env: ## Generate local/.env.$(ENV) once (dev-only credentials, gitignored)
	@scripts/dev-env.sh $(ENV)

deps-up: deps-env ## Start Postgres (pgvector) and Azurite for sdp-$(ENV) and wait until healthy
	@$(COMPOSE) up -d --wait

deps-down: ## Stop sdp-$(ENV), keeping its volumes
	@$(COMPOSE) down

deps-reset: ## Stop sdp-$(ENV) and delete its volumes (data is lost)
	@$(COMPOSE) down -v

deps-ps: ## Show sdp-$(ENV) containers
	@$(COMPOSE) ps

deps-logs: ## Follow sdp-$(ENV) logs
	@$(COMPOSE) logs -f

deps-info: ## Print endpoints and account names for sdp-$(ENV) (never prints passwords or keys)
	@get() { sed -n "s/^$$1=//p" $(ENV_FILE) | tr -d "'"; }; \
	echo "postgres  127.0.0.1:$${SDP_PG_PORT:-55432} db=$$(get POSTGRES_DB) user=$$(get POSTGRES_USER) (password in $(ENV_FILE))"; \
	for a in $$(get AZURITE_ACCOUNTS | tr ';' '\n' | cut -d: -f1); do echo "blob      http://127.0.0.1:$${SDP_BLOB_PORT:-10100}/$$a"; done
