#!/usr/bin/env bash
#
# Seed test users for QA across the whole UI flow.
#
# Creates 5 accounts in the Keycloak realm 'custodiam' and the matching
# rows in the API database (voluntarios + voluntario_roles), so that
# every screen of the app can be exercised against real data without
# manual onboarding. Idempotent: re-running it does not duplicate
# users, BD rows nor role assignments.
#
# Users created
# -------------
#
# | username | password    | rol KC             | BD row | Used to exercise                                            |
# |----------|-------------|--------------------|--------|-------------------------------------------------------------|
# | vol1     | Vol1Pass!   | voluntario         |   yes  | mi-perfil, /voluntarios (lista), "Sin acceso" en alta/ficha |
# | jefe1    | Jefe1Pass!  | jefe_equipo        |   yes  | ficha admin read-only, banner comando operativo             |
# | coord1   | Coord1Pass! | coordinador        |   yes  | admin operativo completo (alta, ficha edit, cambio rol)     |
# | tesor1   | Tesor1Pass! | tesorero           |   yes  | caso edge: lista + ficha sí, editar/crear no                |
# | admin1   | Admin1Pass! | admin              |    no  | admin técnico puro: /mi-perfil debe mostrar "Sin acceso"    |
#
# admin1 intentionally has no BD row: that is exactly the scenario we
# want to verify ("usuario Keycloak sin fila vinculada" → 404 →
# AppEmptyState 'Sin perfil'). Every other user has both the KC
# account and the BD row plus an active assignment in
# voluntario_roles, so the admin ficha shows their role.
#
# Why ASCII-only names: bash on Git Bash for Windows routes subprocess
# arguments through cp1252 before CreateProcessW, which mojibakes any
# non-ASCII literal on the way to curl.exe / docker.exe. ASCII removes
# the encoding hazard entirely and keeps the script portable across
# Git Bash, WSL, Linux and macOS.
#
# Prerequisites
# -------------
#
#   1. The dev stack is up:  ./scripts/dev-up.sh
#   2. The API has applied migrations:  cd ../custodiam-api && uv run alembic upgrade head
#      (the script checks the 'roles' catalog and aborts with a clear
#      error if the canonical 12 roles are not present)
#   3. KEYCLOAK_PASSWORD is available either as env var or in docker/.env
#
# Usage:  ./scripts/seed-test-users.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Load KEYCLOAK_PASSWORD ────────────────────────────────────────────

if [[ -z "${KEYCLOAK_PASSWORD:-}" ]] && [[ -f docker/.env ]]; then
  # shellcheck disable=SC1091
  set -a
  source docker/.env
  set +a
fi

if [[ -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  echo "ERROR: KEYCLOAK_PASSWORD is not set and docker/.env does not provide it." >&2
  exit 1
fi

KC_BASE="${KC_BASE:-http://localhost:8080}"
REALM="custodiam"

# Docker exec target for psql operations. POSTGRES_USER / POSTGRES_DB
# come from docker/.env (already sourced above); the defaults match
# the values shipped in docker/.env.example.
PG_USER="${POSTGRES_USER:-custodiam}"
PG_DB="${POSTGRES_DB:-custodiam}"

# ── Pre-flight: roles catalog must be seeded ──────────────────────────

echo "==> Checking that the 'roles' catalog has been seeded"
ROLES_COUNT=$(
  docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml \
    exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -tA -c "SELECT COUNT(*) FROM roles;" \
    2>/dev/null | tr -d '[:space:]' || echo "0"
)
if [[ "$ROLES_COUNT" -lt 12 ]]; then
  echo "ERROR: tabla 'roles' tiene $ROLES_COUNT filas; se esperan >= 12." >&2
  echo "       Ejecuta primero las migraciones de la API:" >&2
  echo "         cd ../custodiam-api && uv run alembic upgrade head" >&2
  echo "       La migración f76feacaf399 siembra el catálogo canónico." >&2
  exit 1
fi
echo "    catálogo OK ($ROLES_COUNT roles disponibles)"

# ── Admin token from master realm ─────────────────────────────────────

echo "==> Requesting admin token from $KC_BASE"
ACCESS=$(curl -fsSL -X POST \
  "$KC_BASE/realms/master/protocol/openid-connect/token" \
  -d "username=admin" \
  -d "password=$KEYCLOAK_PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  | python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

if [[ -z "$ACCESS" ]]; then
  echo "ERROR: empty admin token (check KEYCLOAK_PASSWORD)." >&2
  exit 1
fi

# ── upsert_kc_user: create/update a user in the custodiam realm ───────
#
# Returns the Keycloak user id via stdout (single line, no decoration).
#
# Usage:
#   kc_id=$(upsert_kc_user <username> <password> <firstName> <lastName> <email> <role1> [role2...])

upsert_kc_user() {
  local username="$1" password="$2" first="$3" last="$4" email="$5"
  shift 5
  local roles=("$@")

  echo "==> Ensuring KC user '$username' exists" >&2

  local existing_id
  existing_id=$(
    curl -fsSL -G "$KC_BASE/admin/realms/$REALM/users" \
      --data-urlencode "username=$username" \
      --data-urlencode "exact=true" \
      -H "Authorization: Bearer $ACCESS" \
    | python -c 'import json,sys
data = json.load(sys.stdin)
print(data[0]["id"] if data else "")'
  )

  local profile_body
  profile_body="{\"firstName\":\"$first\",\"lastName\":\"$last\",\"email\":\"$email\",\"emailVerified\":true,\"enabled\":true}"

  if [[ -z "$existing_id" ]]; then
    echo "    creating user" >&2
    local create_body
    create_body="{\"username\":\"$username\",\"firstName\":\"$first\",\"lastName\":\"$last\",\"email\":\"$email\",\"emailVerified\":true,\"enabled\":true}"
    curl -fsSL -X POST "$KC_BASE/admin/realms/$REALM/users" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "$create_body" >&2
    existing_id=$(
      curl -fsSL -G "$KC_BASE/admin/realms/$REALM/users" \
        --data-urlencode "username=$username" \
        --data-urlencode "exact=true" \
        -H "Authorization: Bearer $ACCESS" \
      | python -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'
    )
  else
    echo "    already exists ($existing_id) — refreshing profile" >&2
    curl -fsSL -X PUT "$KC_BASE/admin/realms/$REALM/users/$existing_id" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "$profile_body" >&2
  fi

  echo "    resetting password (non-temporary)" >&2
  curl -fsSL -X PUT "$KC_BASE/admin/realms/$REALM/users/$existing_id/reset-password" \
    -H "Authorization: Bearer $ACCESS" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$password\",\"temporary\":false}" >&2

  for role in "${roles[@]}"; do
    echo "    granting realm role '$role'" >&2
    local role_id
    role_id=$(
      curl -fsSL "$KC_BASE/admin/realms/$REALM/roles/$role" \
        -H "Authorization: Bearer $ACCESS" \
      | python -c 'import json,sys; print(json.load(sys.stdin)["id"])'
    )
    curl -fsSL -X POST "$KC_BASE/admin/realms/$REALM/users/$existing_id/role-mappings/realm" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "[{\"id\":\"$role_id\",\"name\":\"$role\"}]" >&2
  done

  # Single stdout payload: the KC user id, so the caller can capture
  # it with $(upsert_kc_user ...) and link it to the BD row.
  echo "$existing_id"
}

# ── upsert_db_voluntario: create voluntario row + role assignment ─────
#
# Skips silently if a row with the same keycloak_id already exists
# (idempotent re-runs). Role assignment uses NOT EXISTS to avoid
# duplicates in voluntario_roles.
#
# Usage:
#   upsert_db_voluntario <kc_id> <nombre> <telefono> <municipio> \
#                        <fecha_nac:YYYY-MM-DD> <email> <rol_nombre>

upsert_db_voluntario() {
  local kc_id="$1" nombre="$2" telefono="$3" municipio="$4"
  local fecha_nac="$5" email="$6" rol_nombre="$7"

  echo "==> Ensuring BD row for kc_id $kc_id (rol $rol_nombre)"

  docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml \
    exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 <<-EOSQL
    -- Voluntario row: insert only if no row exists for this keycloak_id.
    -- Using gen_random_uuid() (PostgreSQL native) for the primary key.
    INSERT INTO voluntarios (
      id, keycloak_id, nombre, telefono, municipio, fecha_nacimiento,
      email, estado, fecha_alta, conductor_habilitado
    )
    SELECT
      gen_random_uuid(), '$kc_id', '$nombre', '$telefono', '$municipio',
      DATE '$fecha_nac', '$email', 'activo', CURRENT_DATE, FALSE
    WHERE NOT EXISTS (
      SELECT 1 FROM voluntarios WHERE keycloak_id = '$kc_id'
    );

    -- Active role assignment: insert only if there is no open
    -- assignment (fecha_hasta IS NULL) for this voluntario/rol pair.
    INSERT INTO voluntario_roles (
      id, voluntario_id, rol_id, fecha_desde
    )
    SELECT
      gen_random_uuid(),
      v.id,
      r.id,
      CURRENT_DATE
    FROM voluntarios v
    JOIN roles r ON r.nombre = '$rol_nombre'
    WHERE v.keycloak_id = '$kc_id'
      AND NOT EXISTS (
        SELECT 1 FROM voluntario_roles vr
        WHERE vr.voluntario_id = v.id
          AND vr.rol_id = r.id
          AND vr.fecha_hasta IS NULL
      );
EOSQL
}

# ── Seed users ────────────────────────────────────────────────────────

# vol1 — voluntario operativo. Tiene fila BD + asignación rol.
KC_VOL1=$(upsert_kc_user "vol1" "Vol1Pass!" "Pedro" "Sanchez" \
  "vol1@custodiam.test" "voluntario")
upsert_db_voluntario "$KC_VOL1" "Pedro Sanchez" "600100001" "Zuera" \
  "1990-03-15" "vol1@custodiam.test" "voluntario"

# jefe1 — jefe de equipo. Activa ficha admin read-only + comando.
KC_JEFE1=$(upsert_kc_user "jefe1" "Jefe1Pass!" "Lucia" "Martinez" \
  "jefe1@custodiam.test" "jefe_equipo")
upsert_db_voluntario "$KC_JEFE1" "Lucia Martinez" "600100002" \
  "Villanueva de Gallego" "1985-07-22" "jefe1@custodiam.test" "jefe_equipo"

# coord1 — coordinador. Admin operativo completo.
KC_COORD1=$(upsert_kc_user "coord1" "Coord1Pass!" "Carlos" "Lopez" \
  "coord1@custodiam.test" "coordinador")
upsert_db_voluntario "$KC_COORD1" "Carlos Lopez" "600100003" \
  "San Mateo de Gallego" "1980-11-08" "coord1@custodiam.test" "coordinador"

# tesor1 — tesorero. Caso edge: lectura sí, edición/creación no.
KC_TESOR1=$(upsert_kc_user "tesor1" "Tesor1Pass!" "Marta" "Ruiz" \
  "tesor1@custodiam.test" "tesorero")
upsert_db_voluntario "$KC_TESOR1" "Marta Ruiz" "600100004" "Zuera" \
  "1988-02-19" "tesor1@custodiam.test" "tesorero"

# admin1 — admin técnico puro. Intencionalmente SIN fila en BD: queremos
# verificar que /mi-perfil cae al estado 'Sin perfil' cuando no hay
# row vinculada al keycloak_id. No se llama upsert_db_voluntario.
upsert_kc_user "admin1" "Admin1Pass!" "Admin" "Tecnico" \
  "admin1@custodiam.test" "admin" > /dev/null

echo
echo "==> Done. 5 test users seeded."
echo
echo "    vol1     / Vol1Pass!     (voluntario)"
echo "    jefe1    / Jefe1Pass!    (jefe_equipo)"
echo "    coord1   / Coord1Pass!   (coordinador)"
echo "    tesor1   / Tesor1Pass!   (tesorero)"
echo "    admin1   / Admin1Pass!   (admin, sin row en BD)"
echo
echo "    Login en app.custodiam.es o http://localhost (según entorno)."
