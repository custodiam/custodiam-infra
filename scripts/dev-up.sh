#!/usr/bin/env bash
#
# Bring up the Custodiam dev stack on the developer machine.
#
# Applies the dev override on top of the base compose file, which:
#   - exposes postgres:5432, keycloak:8080, ntfy:8090, api:8000, web:3000
#     to the host (so adb reverse can forward the device to them);
#   - builds api and web from the local source (hot reload on api);
#   - overrides KC_HOSTNAME to http://localhost:8080 so Keycloak emits
#     URLs that match the device traversal via adb reverse (see guía 10
#     §2.6).
#
# Reads docker/.env.sops (encrypted) when present and decrypts it to a
# temp file consumed via `--env-file`. Falls back to docker/.env (plain,
# gitignored) if .env.sops is missing. See guía 04 (gestión de secretos).
#
# Usage: ./scripts/dev-up.sh
#
# Companion scripts:
#   - tunnel-up.sh        public-tunnel mode (auth.custodiam.es)
#   - down.sh             stop and remove the stack (volumes survive)
#   - seed-test-users.sh  create admin/voluntario in the realm

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CLEANUP_FILES=()
trap '[[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}"' EXIT INT TERM
# shellcheck source=./_lib-env.sh
source "$(dirname "$0")/_lib-env.sh"
resolve_env_file

echo "==> Starting Custodiam dev stack (base + dev override)"
# `--build` is required so a `git pull` that brings new runtime deps in
# `custodiam-api/pyproject.toml` (or any change to `custodiam-api/Dockerfile`
# / `custodiam-app/Dockerfile`) is picked up on the next `just dev`.
# Without it Docker Compose reuses the cached `custodiam-api:dev` /
# `custodiam-app:dev` image, the container starts with stale code, and
# uvicorn typically crashes on import. Incremental builds are nearly
# free thanks to BuildKit layer caching (uv sync layer cached by
# pyproject.toml + uv.lock); only changes trigger work. For a truly
# clean rebuild see `just rebuild [service]`.
docker compose \
  --env-file "$ENV_FILE" \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.dev.yml \
  up -d --build

echo
echo "==> Stack status:"
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml ps

cat <<'TIP'

Endpoints (when each container is healthy):
  - Keycloak admin    http://localhost:8080
  - FastAPI Swagger   http://localhost:8000/docs
  - Flutter web       http://localhost:3000
  - ntfy              http://localhost:8090

Next:
  ./scripts/seed-test-users.sh    # ensure admin and voluntario exist in realm

TIP
