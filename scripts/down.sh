#!/usr/bin/env bash
#
# Stop and remove every Custodiam container regardless of the mode it
# was started in. Named volumes (postgres_data, ntfy_data, n8n_data)
# are preserved by default; pass --volumes (or -v) to wipe them too.
#
# Usage:
#   ./scripts/down.sh             # stop containers, preserve volumes
#   ./scripts/down.sh --volumes   # DESTRUCTIVE: also wipe named volumes
#
# Companion scripts:
#   - dev-up.sh, tunnel-up.sh     bring the stack up in either mode
#   - seed-test-users.sh          re-create test users after a --volumes wipe

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

WIPE_VOLUMES=false
for arg in "$@"; do
  case "$arg" in
    --volumes|-v)
      WIPE_VOLUMES=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--volumes|-v]" >&2
      exit 2
      ;;
  esac
done

# Compose's --profile selector only filters what gets included; passing
# every relevant override+profile here makes sure every container the
# project might have created is targeted, irrespective of how it was
# brought up.
DOWN_ARGS=(
  -f docker/docker-compose.yml
  -f docker/docker-compose.dev.yml
  --profile tunnel
  --profile full
  --profile test
  down
  --remove-orphans
)

if $WIPE_VOLUMES; then
  echo "==> Bringing the stack down AND wiping named volumes (destructive)"
  read -r -p "Are you sure? Type 'yes' to proceed: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
  DOWN_ARGS+=(--volumes)
else
  echo "==> Bringing the stack down (named volumes preserved)"
fi

docker compose "${DOWN_ARGS[@]}"

echo
echo "==> Remaining Custodiam containers (should be empty):"
docker ps --filter "name=custodiam-" --format "table {{.Names}}\t{{.Status}}"
