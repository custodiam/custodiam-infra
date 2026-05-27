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
# | username    | password    | rol KC             | BD row | Asignación BD     | Used to exercise                                            |
# |-------------|-------------|--------------------|--------|-------------------|-------------------------------------------------------------|
# | vol1        | vol1        | voluntario         |   yes  | voluntario        | mi-perfil, /voluntarios (lista), "Sin acceso" en alta/ficha |
# | jefe1       | jefe1       | jefe_equipo        |   yes  | jefe_equipo       | ficha admin read-only, banner comando operativo             |
# | coord1      | coord1      | coordinador        |   yes  | coordinador       | admin operativo completo (alta, ficha edit, cambio rol)     |
# | tesor1      | tesor1      | tesorero           |   yes  | tesorero          | caso edge: lista + ficha sí, editar/crear no                |
# | admin       | admin       | admin              |   yes  | admin             | flujos del admin técnico (permisos sistema.*)               |
# | reviewstore | reviewstore | coordinador+admin  |   yes  | coordinador       | cuenta de revisión de stores: cobertura total (operativa+sistema) |
# | superadmin  | superadmin  | coordinador+admin  |   yes  | coordinador       | cuenta de emergencia del equipo: cobertura total            |
#
# Doctrina del seed: las siete cuentas siguen el patrón password =
# username. Es deliberadamente débil porque el repo es público y las
# credenciales aparecen en el book público (docs.custodiam.es) y, en
# el caso de reviewstore, en la submission de Google Play y Apple
# App Store. Esto NO es una postura sobre seguridad de producción
# real: estas cuentas son SACRIFICABLES y solo se usan para QA del
# equipo, defensa académica y review de stores. Cuando una
# agrupación adopte Custodiam para uso productivo real, las cuentas
# humanas se crean por el flujo normal de alta de voluntario y este
# seed deja de ejecutarse.
#
# Las dos cuentas con admin + coordinador (reviewstore y superadmin)
# están separadas por audiencia, no por capacidad: reviewstore es
# visible a Google Play / Apple, superadmin es para administración
# interna del piloto. Permite rotar credenciales o eliminar una sin
# afectar a la otra.
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
#   3. KEYCLOAK_PASSWORD is available via either:
#      - docker/.env.sops      decrypted on the fly with sops+age (preferred,
#                              same flow as dev-up.sh / prod-up.sh)
#      - docker/.env           plain dotenv file (fallback for bootstrap)
#      - the calling shell     (env var inline before the script)
#
# Usage:  ./scripts/seed-test-users.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Resolve env file (sops+age aware) ─────────────────────────────────
#
# Same pattern used by dev-up.sh, tunnel-up.sh and prod-up.sh: descifra
# docker/.env.sops con sops+age si está presente, o usa docker/.env como
# fallback. Tras `resolve_env_file`, $ENV_FILE apunta al archivo correcto
# (o tempfile descifrado con `chmod 600`). El trap de limpieza borra
# cualquier tempfile que `_lib-env.sh` haya creado en CLEANUP_FILES.
#
# Acto seguido se hace `source` del archivo resuelto para exportar
# KEYCLOAK_PASSWORD (y el resto de variables) al entorno del script.
# Sin esto, el `curl` contra la Admin API de Keycloak no podría
# autenticarse.

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

# Docker exec target for psql operations. POSTGRES_USER / POSTGRES_DB
# come from docker/.env (already sourced above); the defaults match
# the values shipped in docker/.env.example.
PG_USER="${POSTGRES_USER:-custodiam}"
PG_DB="${POSTGRES_DB:-custodiam}"

# Compose override applied on top of docker-compose.yml when running
# `docker compose exec postgres`. Defaults to the dev override (local
# stack with exposed ports) but can be set to the prod override when
# seeding against the productive stack from the host server:
#
#   COMPOSE_OVERRIDE=docker/docker-compose.prod.yml \
#   KC_BASE=https://auth.custodiam.es \
#   KEYCLOAK_PASSWORD=<el real> \
#     ./scripts/seed-test-users.sh
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-docker/docker-compose.dev.yml}"

# ── Pre-flight: roles catalog must be seeded ──────────────────────────

echo "==> Checking that the 'roles' catalog has been seeded"
ROLES_COUNT=$(
  docker compose -f docker/docker-compose.yml -f "$COMPOSE_OVERRIDE" \
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

  docker compose -f docker/docker-compose.yml -f "$COMPOSE_OVERRIDE" \
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
KC_VOL1=$(upsert_kc_user "vol1" "vol1" "Pedro" "Sanchez" \
  "vol1@custodiam.test" "voluntario")
upsert_db_voluntario "$KC_VOL1" "Pedro Sanchez" "600100001" "Zuera" \
  "1990-03-15" "vol1@custodiam.test" "voluntario"

# jefe1 — jefe de equipo. Activa ficha admin read-only + comando.
KC_JEFE1=$(upsert_kc_user "jefe1" "jefe1" "Lucia" "Martinez" \
  "jefe1@custodiam.test" "jefe_equipo")
upsert_db_voluntario "$KC_JEFE1" "Lucia Martinez" "600100002" \
  "Villanueva de Gallego" "1985-07-22" "jefe1@custodiam.test" "jefe_equipo"

# coord1 — coordinador. Admin operativo completo.
KC_COORD1=$(upsert_kc_user "coord1" "coord1" "Carlos" "Lopez" \
  "coord1@custodiam.test" "coordinador")
upsert_db_voluntario "$KC_COORD1" "Carlos Lopez" "600100003" \
  "San Mateo de Gallego" "1980-11-08" "coord1@custodiam.test" "coordinador"

# tesor1 — tesorero. Caso edge: lectura sí, edición/creación no.
KC_TESOR1=$(upsert_kc_user "tesor1" "tesor1" "Marta" "Ruiz" \
  "tesor1@custodiam.test" "tesorero")
upsert_db_voluntario "$KC_TESOR1" "Marta Ruiz" "600100004" "Zuera" \
  "1988-02-19" "tesor1@custodiam.test" "tesorero"

# admin — admin técnico puro del catálogo de roles. Tiene fila en BD
# con asignación del rol admin para que /mi-perfil renderice su perfil
# y la sección de roles muestre 'admin' explícitamente. El flujo edge
# 'usuario Keycloak sin fila BD vinculada' sigue cubierto por código
# (AppEmptyState) y por tests E2E del mock OIDC server; no necesita un
# usuario seed específico para reproducirlo.
KC_ADMIN=$(upsert_kc_user "admin" "admin" "Admin" "Tecnico" \
  "admin@custodiam.test" "admin")
upsert_db_voluntario "$KC_ADMIN" "Admin Tecnico" "600100005" "Zaragoza" \
  "1980-01-01" "admin@custodiam.test" "admin"

# reviewstore — cuenta pública para la revisión de Google Play y App
# Store. Doble rol en Keycloak (coordinador + admin) para cobertura
# total: el coordinador habilita todo el dominio operativo (servicios,
# voluntarios, inventario, fichaje, notificaciones) y admin añade los
# permisos sistema.*. Fila en BD con asignación de coordinador para
# que /mi-perfil renderice un perfil válido; el admin no se
# materialisa en voluntario_roles porque cuando hay solapamiento
# coord+admin, coord es el rol operativo "visible" en la ficha.
# Password = username porque la credencial aparece en la submission
# pública de las stores.
KC_REVIEW=$(upsert_kc_user "reviewstore" "reviewstore" "Review" "Stores" \
  "reviewstore@custodiam.test" "coordinador" "admin")
upsert_db_voluntario "$KC_REVIEW" "Review Stores" "600100099" "Zaragoza" \
  "1990-01-01" "reviewstore@custodiam.test" "coordinador"

# superadmin — cuenta de emergencia del equipo. Misma cobertura que
# reviewstore (coordinador + admin) pero con audiencia distinta:
# administración interna del piloto, no revisión externa. Permite
# rotar credenciales o eliminar reviewstore sin perder acceso de
# emergencia, y viceversa.
KC_SUPER=$(upsert_kc_user "superadmin" "superadmin" "Super" "Admin" \
  "superadmin@custodiam.test" "coordinador" "admin")
upsert_db_voluntario "$KC_SUPER" "Super Admin" "600100098" "Zaragoza" \
  "1985-01-01" "superadmin@custodiam.test" "coordinador"

echo
echo "==> Done. 7 test users seeded."
echo
echo "    vol1        / vol1        (voluntario)"
echo "    jefe1       / jefe1       (jefe_equipo)"
echo "    coord1      / coord1      (coordinador)"
echo "    tesor1      / tesor1      (tesorero)"
echo "    admin       / admin       (admin tecnico, con row en BD)"
echo "    reviewstore / reviewstore (coordinador + admin, cuenta de stores)"
echo "    superadmin  / superadmin  (coordinador + admin, cuenta de emergencia del equipo)"
echo
echo "    Login en app.custodiam.es o http://localhost (segun entorno)."
