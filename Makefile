SHELL := /bin/bash
# Local SDP stack. ENV selects config/environments/$(ENV).yaml (default dev) and the namespace:
# project sdp-$(ENV), containers <svc>-$(ENV). Non-secret values come only from that YAML file.
ENV ?= dev
ENV_YAML := config/environments/$(ENV).yaml
CONFIG_FILE := local/.config.$(ENV)
ENV_FILE := local/.env.$(ENV)
COMPOSE := docker compose -f local/compose.yaml --env-file $(ENV_FILE) --env-file $(CONFIG_FILE) --profile deps
CHECK_JSONSCHEMA := check-jsonschema

CORE_DIR ?= $(abspath ../newco-sdp-core)
APP_COMPOSE := SDP_APP_ENV_DIR=$(CORE_DIR) docker compose -f local/compose.yaml --env-file $(ENV_FILE) --env-file $(CONFIG_FILE) --profile deps --profile app
APP_SERVICES := migrate-bootstrap migrate locker seal-worker

.PHONY: app-up app-down app-logs
app-up: deps-up ## Start the app profile (in core first: make images app-env) and wait for /readyz
	@for f in migrate locker seal-worker; do test -f $(CORE_DIR)/.env.app.$(ENV).$$f || \
	  { echo "missing $(CORE_DIR)/.env.app.$(ENV).$$f: run make app-env in core"; exit 1; }; done
	@$(APP_COMPOSE) up -d
	@for u in 18081/readyz 18091/readyz; do for i in $$(seq 60); do \
	  curl -fsS -o /dev/null http://127.0.0.1:$$u && echo "ready: $$u" && break; \
	  [ $$i = 60 ] && { echo "not ready: $$u"; exit 1; }; sleep 1; done; done

app-down: env-render ## Stop and remove the app profile containers; deps keep running
	@$(APP_COMPOSE) rm --stop --force $(APP_SERVICES)

app-logs: env-render ## Follow the app profile logs
	@$(APP_COMPOSE) logs -f $(APP_SERVICES)

TF_IDP := terraform -chdir=terraform/envs/dev
.PHONY: idp-apply idp-issuers
idp-apply: deps-up ## Apply the lab and clients realms to keycloak-$(ENV) (local state in local/, gitignored)
	@$(TF_IDP) init -input=false -backend-config=path=$(abspath local/terraform-$(ENV).tfstate) >/dev/null
	@TF_VAR_keycloak_admin_password=$$(sed -n 's/^KEYCLOAK_ADMIN_PASSWORD=//p' $(ENV_FILE)) \
	  $(TF_IDP) apply -input=false -auto-approve

idp-issuers: ## Print the issuer URLs (secrets: terraform -chdir=terraform/envs/dev output -json)
	@$(TF_IDP) output issuers

AZ_ENV ?= azdev
TF_AZ := terraform -chdir=terraform/envs/dev-storage
AZ_KEYCHAIN_ITEM ?= sp-tf-workload-sdp-dev
AZ_SUB := $(shell sed -n 's/^ *subscription_id: *\([0-9a-f-]*\).*/\1/p' config/environments/$(AZ_ENV).yaml)
.PHONY: azure-check azure-plan azure-apply azure-router-start azure-router-stop
azure-check: ## Format, validate and policy-test the Azure Terraform (no Azure access)
	@terraform fmt -check -recursive terraform
	@for d in terraform/modules/storage-accounts terraform/modules/dev-network terraform/envs/dev-storage; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate -no-color && terraform -chdir=$$d test -no-color || exit 1; done

azure-plan: azure-check ## Plan the Azure dev stamp (I3a: plan only; apply is I3b, from the tailnet)
	@test "$$(az account show --query id -o tsv 2>/dev/null)" = "$(AZ_SUB)" || \
	  { echo "active az subscription is not $(AZ_ENV)'s: az account set --subscription $(AZ_SUB)"; exit 1; }
	@$(TF_AZ) init -input=false -reconfigure -backend-config=path=$(abspath local/terraform-$(AZ_ENV)-storage.tfstate) >/dev/null
	@TF_VAR_client_certificate_password="$$(security find-generic-password -s $(AZ_KEYCHAIN_ITEM) -w)" \
	  TF_VAR_tailscale_auth_key="$$(security find-generic-password -s tailscale-sdp-dev -w 2>/dev/null)" \
	  $(TF_AZ) plan -input=false -var env_file=../../../config/environments/$(AZ_ENV).yaml

# I3b, in stages: rg (then grant the RG-scoped roles), net (everything reachable over Resource Manager; then
# approve the router's route and split DNS in Tailscale), key (data plane, over the tailnet).
AZ_TF_ENV = TF_VAR_client_certificate_password="$$(security find-generic-password -s $(AZ_KEYCHAIN_ITEM) -w)" \
	  TF_VAR_tailscale_auth_key="$$(security find-generic-password -s tailscale-sdp-dev -w 2>/dev/null)"
AZ_TARGETS_rg  := -target=azurerm_resource_group.this
AZ_TARGETS_net := -target=module.storage -target=module.network -target=azurerm_key_vault.this \
	  -target=azurerm_role_assignment.blob_owner -target=azurerm_role_assignment.crypto_user
AZ_TARGETS_key :=
azure-apply: azure-check ## Apply the Azure dev stamp: STAGE=rg|net|key [APPROVE=1] (I3b)
	@case "$(STAGE)" in rg|net|key) ;; *) echo "STAGE=rg|net|key"; exit 1;; esac
	@test "$$(az account show --query id -o tsv 2>/dev/null)" = "$(AZ_SUB)" || \
	  { echo "active az subscription is not $(AZ_ENV)'s: az account set --subscription $(AZ_SUB)"; exit 1; }
	@$(TF_AZ) init -input=false -reconfigure -backend-config=path=$(abspath local/terraform-$(AZ_ENV)-storage.tfstate) >/dev/null
	@$(AZ_TF_ENV) $(TF_AZ) apply -input=false $(if $(APPROVE),-auto-approve) -var env_file=../../../config/environments/$(AZ_ENV).yaml $(AZ_TARGETS_$(STAGE))

AZ_RG := $(shell sed -n 's/^naming: { client: \([a-z]*\), project: \([a-z]*\), instance: \([0-9]\), stage: \([a-z]*\) }.*/\1-\2-rg-\3-\4/p' config/environments/$(AZ_ENV).yaml)
AZ_VM := $(subst -rg-,-vm-,$(AZ_RG))
azure-router-start: ## Start the Tailscale router VM (it stops itself each evening)
	@az vm start -g $(AZ_RG) -n $(AZ_VM) --subscription $(AZ_SUB) -o none && echo "started $(AZ_VM)"

azure-router-stop: ## Deallocate the router VM (no compute charge while stopped)
	@az vm deallocate -g $(AZ_RG) -n $(AZ_VM) --subscription $(AZ_SUB) -o none && echo "deallocated $(AZ_VM)"

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
