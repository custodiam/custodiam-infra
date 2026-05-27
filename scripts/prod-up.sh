#!/usr/bin/env bash
#
# Bring up the Custodiam production stack on the host.
#
# Applies the prod override on top of the base compose file, which:
#   - keeps KC_HOSTNAME=auth.${DOMAIN} (base value, public);
#   - tightens to KC_HOSTNAME_STRICT=true (Host header validation);
#   - sets DEBUG=false on the API.
#
# cloudflared remains in the [tunnel] profile declared in the base file,
# so this script invokes compose with --profile tunnel (same as
# tunnel-up.sh). The prod override applies only to services already in
# the default profile (keycloak, api).
#
# Reads docker/.env.sops (encrypted) when present and decrypts it to a
# temp file consumed via `--env-file`. Falls back to docker/.env (plain,
# gitignored) if .env.sops is missing. See guía 04 (gestión de secretos).
#
# Usage:
#   ./scripts/prod-up.sh
#
# Companion scripts:
#   - dev-up.sh           local-machine dev mode (localhost)
#   - tunnel-up.sh        staging via tunnel (no prod hardening)
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

# Guard 1: a previous stack (dev or tunnel) would inherit the wrong config.
RUNNING=$(docker ps --filter "label=com.docker.compose.project=custodiam" --format '{{.Names}}' | wc -l | tr -d ' ')
if [[ "$RUNNING" -gt 0 ]]; then
  cat >&2 <<EOF
ERROR: Custodiam containers are already running:
$(docker ps --filter "label=com.docker.compose.project=custodiam" --format '  - {{.Names}} ({{.Image}})')

prod-up.sh applies the prod override (KC_HOSTNAME_STRICT=true, DEBUG=false,
cloudflared lifted out of the [tunnel] profile) and cannot reuse a stack
that was started in dev or tunnel mode. Bring it down first:

  ./scripts/down.sh

Then re-run prod-up.sh.
EOF
  exit 1
fi

# Guard 2: cloudflared cannot connect without the tunnel token.
if ! grep -q "^CLOUDFLARE_TUNNEL_TOKEN=." "$ENV_FILE"; then
  echo "ERROR: CLOUDFLARE_TUNNEL_TOKEN is missing or empty in the env file." >&2
  echo "       Production mode starts cloudflared automatically and needs the token." >&2
  echo "       See guía 02 (Cloudflare) and guía 04 (sops)." >&2
  exit 1
fi

echo "==> Pulling images from GHCR (api, web, cloudflared)"
docker compose \
  --env-file "$ENV_FILE" \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.prod.yml \
  --profile tunnel \
  pull

echo
echo "==> Starting Custodiam production stack (base + prod override + tunnel profile)"
docker compose \
  --env-file "$ENV_FILE" \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.prod.yml \
  --profile tunnel \
  up -d

echo
echo "==> Stack status:"
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml --profile tunnel ps

cat <<'TIP'

Public endpoints (when cloudflared shows "Connection registered"):
  - Keycloak       https://auth.custodiam.es
  - FastAPI        https://api.custodiam.es
  - Flutter web    https://app.custodiam.es
  - ntfy           https://ntfy.custodiam.es

Smoke tests:
  curl -fsSL https://auth.custodiam.es/realms/custodiam/.well-known/openid-configuration | head
  curl -I    https://app.custodiam.es/.well-known/assetlinks.json
  curl -I    https://app.custodiam.es/.well-known/apple-app-site-association

TIP
