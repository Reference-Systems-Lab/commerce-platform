# The platform's commands: run `make` to list them. Compose does the work, and anything longer than a
# line lives in scripts/ as POSIX sh, so each command behaves the same on WSL2, macOS and Linux.

.DEFAULT_GOAL := help
.PHONY: help up down reset logs smoke trust untrust hosts

# Stopping creates nothing, so it needs no credentials. The placeholders let Compose read compose.yaml
# when .env is missing or incomplete; without them `make reset` fails in exactly the case bootstrap
# sends you to it (a credential missing while its data volume still exists).
COMPOSE_STOP = RABBITMQ_PASSWORD=unused MEILI_MASTER_KEY=unused docker compose

help: ## List the commands
	@grep -E '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*## " } { printf "  %-8s %s\n", $$1, $$2 }'

up: ## Start the platform and wait until every service is healthy
	@for f in .env secrets/postgres_password certs/leaf/cert.pem certs/leaf/key.pem; do \
		[ -f "$$f" ] || { echo "error: $$f is missing. Run 'make bootstrap' first." >&2; exit 1; }; \
	done
	docker compose up --detach --wait

down: ## Stop the platform and keep its data
	@$(COMPOSE_STOP) down

reset: ## Stop the platform and delete its data; keeps .env, secrets/ and certs/ (CONFIRM=yes skips the question)
	@if [ "$(CONFIRM)" != yes ]; then \
		printf 'This deletes the Postgres, Valkey, RabbitMQ, Mailpit and Meilisearch data. Type yes to continue: '; \
		read -r answer; \
		[ "$$answer" = yes ] || { echo 'Cancelled. Nothing was deleted.'; exit 1; }; \
	fi
	@$(COMPOSE_STOP) down --volumes --remove-orphans

logs: ## Follow the logs (s=<service> for one service)
	docker compose logs --follow $(s)

smoke: ## Check the running platform end to end
	@sh ./scripts/smoke.sh

trust: ## Trust the platform's root certificate in your browsers (asks you once)
	@sh ./scripts/trust.sh

untrust: ## Remove every root certificate this platform created from your trust store
	@sh ./scripts/trust.sh untrust

hosts: ## Point the local addresses at 127.0.0.1 in your hosts file (asks once to elevate)
	@sh ./scripts/hosts.sh
