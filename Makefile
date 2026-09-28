.PHONY: prepare check build up down restart status logs verify verify-release test-edge

COMPOSE = docker compose --env-file env/compose.env -f docker-compose.yml

# Create the working env files next to the examples (never overwrites).
prepare:
	./scripts/prepare-env.sh

# Placeholders, key formats, proxy subnets and the Compose model.
check:
	./scripts/check-config.sh

build: check
	$(COMPOSE) build

up: check
	$(COMPOSE) up -d --build --wait

down:
	$(COMPOSE) down

restart: down up

status:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

# Release integrity plus the running installation's health and version.
verify:
	./scripts/verify.sh

# Release integrity only, before anything is built or started: the checksums
# and the release index signed with the Atlas release key.
verify-release:
	sha256sum -c SHA256SUMS
	./artifacts/linux-amd64/atlas-update-check -verify .

# Route contract of the edge in both modes, on throwaway containers.
test-edge:
	./scripts/test-edge.sh
