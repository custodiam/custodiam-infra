#!/usr/bin/env bash
#
# Bring up the Custodiam stack in public-tunnel mode.
#
# Uses the base compose file only (no dev override) so:
#   - KC_HOSTNAME stays at auth.${DOMAIN}, which is what Cloudflare
#     Tunnel needs to emit public URLs (see guía 10 §2.6);
#   - service ports stay internal to the Docker network (no host
#     bindings), so the only public path is through the tunnel;
#   - api and web are pulled from GHCR. Both packages are public
#     (see guía 00 §"Paso 1bis" and ADR-020), so the pull works without
#     `docker login`. Use --skip-images to start only postgres + keycloak
#     + cloudflared when iterating on the SSO without rebuilding app/api.
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

# Guard 1: a previous stack (dev or prod) would inherit the wrong config.
# In particular, dev-up.sh sets KC_HOSTNAME=http://localhost:8080 on
# Keycloak; if we silently up on top of that the OIDC flow breaks when
# accessed through the tunnel. See ADR-020.
RUNNING=$(docker ps --filter "label=com.docker.compose.project=custodiam" --format '{{.Names}}' | wc -l | tr -d ' ')
if [[ "$RUNNING" -gt 0 ]]; then
  cat >&2 <<EOF
ERROR: Custodiam containers are already running:
$(docker ps --filter "label=com.docker.compose.project=custodiam" --format '  - {{.Names}} ({{.Image}})')

tunnel-up.sh applies a different compose composition (no dev override,
KC_HOSTNAME=auth.\${DOMAIN}, --profile tunnel) and cannot reuse a stack
that was started in dev or prod mode. Bring it down first:

  ./scripts/down.sh

Then re-run tunnel-up.sh.
EOF
  exit 1
fi

# Guard 2: cloudflared cannot connect without the tunnel token.
if ! grep -q "^CLOUDFLARE_TUNNEL_TOKEN=." "$ENV_FILE"; then
  echo "ERROR: CLOUDFLARE_TUNNEL_TOKEN is missing or empty in the env file." >&2
  echo "       cloudflared cannot connect without it." >&2
  echo "       See guía 02 (Cloudflare) and guía 04 (sops)." >&2
  exit 1
fi

if $SKIP_IMAGES; then
  echo "==> Starting tunnel stack WITHOUT api/web (skip-images mode)"
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel up -d postgres keycloak
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel up -d cloudflared --no-deps
else
  echo "==> Pulling images from GHCR (api, web)"
  docker compose --env-file "$ENV_FILE" -f docker/docker-compose.yml --profile tunnel pull
  echo
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
