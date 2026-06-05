#!/usr/bin/env bash
#
# Delete a user by email from BOTH Keycloak and the custodiam database.
#
# Utility for cleaning up test/throwaway accounts left behind during QA.
# It removes:
#   1. The Keycloak user in the 'custodiam' realm whose email matches.
#   2. The voluntario row in the custodiam DB whose email matches, plus
#      every child row that references it (discovered dynamically from
#      the foreign keys, so no table is ever forgotten).
#
# Both sides are handled independently and idempotently: if the user only
# exists on one side, that side is cleaned and the other is reported as
# "not found" without failing.
#
# Env resolution (KEYCLOAK_PASSWORD, POSTGRES_*) is the same sops+age aware
# flow as seed-test-users.sh / dev-up.sh / prod-up.sh.
#
# Usage:
#   ./scripts/delete-user-by-email.sh <email> [--yes]
#
#   --yes / -y   skip the interactive confirmation (for scripted use)
#
# Dev (default, Keycloak on http://localhost:8080):
#   just delete-user alguien@ejemplo.com
#
# Prod (Keycloak on https://auth.custodiam.es, prod compose override):
#   just delete-user-prod alguien@ejemplo.com

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Args ──────────────────────────────────────────────────────────────
EMAIL="${1:-}"
ASSUME_YES=0
case "${2:-}" in
  --yes|-y) ASSUME_YES=1 ;;
  "") ;;
  *) echo "ERROR: opcion no reconocida: ${2}" >&2; exit 1 ;;
esac

if [[ -z "$EMAIL" || "$EMAIL" != *@* ]]; then
  echo "Usage: $0 <email> [--yes]" >&2
  echo "       el primer argumento debe ser un email valido" >&2
  exit 1
fi

# ── Resolve env file (sops+age aware), same pattern as seed-test-users.sh ─
CLEANUP_FILES=()
trap '[[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}"' EXIT INT TERM
# shellcheck source=./_lib-env.sh
source "$(dirname "$0")/_lib-env.sh"
resolve_env_file
# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

if [[ -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  echo "ERROR: KEYCLOAK_PASSWORD no aparece en el archivo de entorno." >&2
  echo "       Revisa docker/.env.sops (cifrado) o docker/.env (plano)." >&2
  exit 1
fi

KC_BASE="${KC_BASE:-http://localhost:8080}"
REALM="custodiam"
PG_USER="${POSTGRES_USER:-custodiam}"
PG_DB="${POSTGRES_DB:-custodiam}"
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-docker/docker-compose.dev.yml}"

dc() {
  docker compose -f docker/docker-compose.yml -f "$COMPOSE_OVERRIDE" "$@"
}

# ── 1. Admin token (master realm) ─────────────────────────────────────
echo "==> Pidiendo token de admin a $KC_BASE"
ACCESS=$(curl -fsSL -X POST \
  "$KC_BASE/realms/master/protocol/openid-connect/token" \
  -d "username=${KEYCLOAK_ADMIN:-admin}" \
  -d "password=$KEYCLOAK_PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  | python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

if [[ -z "$ACCESS" ]]; then
  echo "ERROR: token de admin vacio (revisa KEYCLOAK_PASSWORD)." >&2
  exit 1
fi

# ── 2. Look up the Keycloak user(s) by email ──────────────────────────
echo "==> Buscando en Keycloak el email '$EMAIL'"
KC_IDS=$(
  curl -fsSL -G "$KC_BASE/admin/realms/$REALM/users" \
    --data-urlencode "email=$EMAIL" \
    --data-urlencode "exact=true" \
    -H "Authorization: Bearer $ACCESS" \
  | python -c 'import json,sys
for u in json.load(sys.stdin):
    print(u["id"], u.get("username",""))'
)

# ── 3. Look up the custodiam voluntario(s) by email ───────────────────
echo "==> Buscando en la BBDD custodiam el email '$EMAIL'"
DB_ROWS=$(
  dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tA \
    -v email="$EMAIL" \
    -c "SELECT id || '  ' || nombre FROM voluntarios WHERE email = :'email';" \
    2>/dev/null | sed '/^$/d' || true
)

# ── Summary + confirmation ────────────────────────────────────────────
echo
echo "----------------------------------------------------------------"
echo "  Email objetivo : $EMAIL"
echo "  Keycloak       : ${KC_IDS:-<no encontrado>}"
echo "  custodiam BBDD : ${DB_ROWS:-<no encontrado>}"
echo "----------------------------------------------------------------"

if [[ -z "$KC_IDS" && -z "$DB_ROWS" ]]; then
  echo "Nada que borrar: el email no existe ni en Keycloak ni en la BBDD."
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  printf "Borrar DEFINITIVAMENTE este usuario de ambos sistemas? [y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Cancelado."; exit 0 ;;
  esac
fi

# ── 4. Delete from Keycloak ───────────────────────────────────────────
if [[ -n "$KC_IDS" ]]; then
  while read -r kc_id _username; do
    [[ -z "$kc_id" ]] && continue
    echo "==> Borrando de Keycloak: $kc_id ($_username)"
    curl -fsS -X DELETE "$KC_BASE/admin/realms/$REALM/users/$kc_id" \
      -H "Authorization: Bearer $ACCESS"
  done <<< "$KC_IDS"
else
  echo "==> Keycloak: nada que borrar."
fi

# ── 5. Delete from custodiam DB (children discovered from FKs) ─────────
if [[ -n "$DB_ROWS" ]]; then
  echo "==> Borrando de la BBDD custodiam (voluntario + filas hijas)"
  dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 -v email="$EMAIL" <<'EOSQL'
SELECT set_config('delete_user.email', :'email', false);
DO $$
DECLARE
  target text := current_setting('delete_user.email');
  vids   uuid[];
  fk     record;
  n      int;
BEGIN
  SELECT array_agg(id) INTO vids FROM voluntarios WHERE email = target;
  IF vids IS NULL THEN
    RAISE NOTICE 'custodiam: sin voluntario con email %', target;
    RETURN;
  END IF;

  -- Borra de toda tabla con FK -> voluntarios, descubierta en runtime.
  FOR fk IN
    SELECT conrelid::regclass::text AS tbl, a.attname AS col
    FROM pg_constraint c
    JOIN pg_attribute a
      ON a.attnum = ANY(c.conkey) AND a.attrelid = c.conrelid
    WHERE c.confrelid = 'voluntarios'::regclass AND c.contype = 'f'
  LOOP
    EXECUTE format('DELETE FROM %s WHERE %I = ANY($1)', fk.tbl, fk.col)
      USING vids;
  END LOOP;

  DELETE FROM voluntarios WHERE id = ANY(vids);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'custodiam: borrados % voluntario(s)', n;
END $$;
EOSQL
else
  echo "==> custodiam BBDD: nada que borrar."
fi

echo
echo "==> Listo. '$EMAIL' eliminado de los sistemas donde existia."
