#!/usr/bin/env bash
#
# Bring up the Custodiam stack in public-tunnel mode.
#
# Uses the base compose file only (no dev override) so:
#   - KC_HOSTNAME stays at auth.${DOMAIN}, which is what Cloudflare
#     Tunnel needs to emit public URLs (see guía 10 §2.6);
#   - service ports stay internal to the Docker network (no host
#     bindings), so the only public path is through the tunnel;
#   - api and web are pulled from GHCR. If those pulls fail (private
#     registry or rate-limited), use --skip-images to avoid them.
#
# Reads docker/.env.sops (encrypted) when present and decrypts it to a
# temp file consumed via `--env-file`. Falls back to docker/.env (plain,
# gitignored) if .env.sops is missing. See guía 04 (gestión de secretos).
#
# Usage:
#   ./scripts/tunnel-up.sh                       # full stack via tunnel
#   ./scripts/tunnel-up.sh --skip-images         # only postgres + keycloak
#                                                  + cloudflared (no api/web)
#
# Companion scripts:
#   - dev-up.sh           local-machine dev mode (localhost:8080)
#   - down.sh             stop and remove the stack
#   - seed-test-users.sh  create admin/voluntario in the realm

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_IMAGES=false
for arg in "$@"; do
  case "$arg" in
    --skip-images)
      SKIP_IMAGES=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--skip-images]" >&2
      exit 2
      ;;
  esac
done

CLEANUP_FILES=()
trap '[[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}"' EXIT INT TERM
# shellcheck source=./_lib-env.sh
source "$(dirname "$0")/_lib-env.sh"
resolve_env_file

if $SKIP_IMAGES; then
  echo "==> Starting tunnel stack WITHOUT api/web (skip-images mode)"
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel up -d postgres keycloak
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel up -d cloudflared --no-deps
else
  echo "==> Starting tunnel stack (full)"
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel up -d
fi

echo
echo "==> Stack status:"
docker compose -f docker/docker-compose.yml --profile tunnel ps

cat <<'TIP'

Public endpoints (when cloudflared shows "Connection registered"):
  - Keycloak       https://auth.custodiam.es
  - FastAPI        https://api.custodiam.es
  - Flutter web    https://app.custodiam.es
  - ntfy           https://ntfy.custodiam.es

Smoke test:
  curl -fsSL https://auth.custodiam.es/realms/custodiam/.well-known/openid-configuration | head

TIP
