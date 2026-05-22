#!/usr/bin/env bash
#
# Create the two test users that guía 10 §9 documents in the realm
# 'custodiam'. Idempotent: re-running it does not duplicate users.
#
# - admin       / Admin1234   roles: admin, coordinador
# - voluntario  / Volunt1234   roles: voluntario        (first/last: Maria Garcia)
#
# Required: Keycloak reachable at http://localhost:8080 and the
# 'master' realm admin password available in either:
#   - the KEYCLOAK_PASSWORD env var,
#   - or the docker/.env file as KEYCLOAK_PASSWORD=...
#
# Why this script exists: a partial realm export does not include
# users. Without this script, every fresh stack (or every wipe of
# postgres_data) forces the developer to recreate the two test users
# by hand through the Keycloak Admin Console.
#
# Why ASCII-only firstName/lastName: bash on Git Bash for Windows
# routes subprocess arguments through the MSYS ANSI code page
# (cp1252) before CreateProcessW, which mojibakes any non-ASCII
# literal on the way to curl.exe / python.exe. Test users do not
# need diacritics to verify the OIDC flow, so keeping them ASCII
# removes the encoding hazard entirely and makes the script
# portable across Git Bash, WSL, Linux and macOS with no special
# handling.
#
# Usage: ./scripts/seed-test-users.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Load KEYCLOAK_PASSWORD from docker/.env if it is not already exported.
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

# upsert_user <username> <password> <firstName> <lastName> <email> <role1> [role2...]
upsert_user() {
  local username="$1" password="$2" first="$3" last="$4" email="$5"
  shift 5
  local roles=("$@")

  echo "==> Ensuring user '$username' exists"

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
    echo "    creating user"
    local create_body
    create_body="{\"username\":\"$username\",\"firstName\":\"$first\",\"lastName\":\"$last\",\"email\":\"$email\",\"emailVerified\":true,\"enabled\":true}"
    curl -fsSL -X POST "$KC_BASE/admin/realms/$REALM/users" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "$create_body"
    existing_id=$(
      curl -fsSL -G "$KC_BASE/admin/realms/$REALM/users" \
        --data-urlencode "username=$username" \
        --data-urlencode "exact=true" \
        -H "Authorization: Bearer $ACCESS" \
      | python -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'
    )
  else
    echo "    already exists ($existing_id) — ensuring profile is up to date"
    curl -fsSL -X PUT "$KC_BASE/admin/realms/$REALM/users/$existing_id" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "$profile_body"
  fi

  echo "    resetting password (non-temporary)"
  curl -fsSL -X PUT "$KC_BASE/admin/realms/$REALM/users/$existing_id/reset-password" \
    -H "Authorization: Bearer $ACCESS" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$password\",\"temporary\":false}"

  # Assign realm roles (idempotent: Keycloak ignores duplicates).
  # Body must carry only id + name; the full role object includes a
  # description with non-ASCII characters ("Máxima autoridad...")
  # that the bash → curl handoff would mangle, making Keycloak
  # return 400 "Cannot parse the JSON".
  for role in "${roles[@]}"; do
    echo "    granting role '$role'"
    local role_id
    role_id=$(
      curl -fsSL "$KC_BASE/admin/realms/$REALM/roles/$role" \
        -H "Authorization: Bearer $ACCESS" \
      | python -c 'import json,sys; print(json.load(sys.stdin)["id"])'
    )
    curl -fsSL -X POST "$KC_BASE/admin/realms/$REALM/users/$existing_id/role-mappings/realm" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -d "[{\"id\":\"$role_id\",\"name\":\"$role\"}]"
  done
}

upsert_user "admin"      "Admin1234"  "Admin" "Custodiam" "admin@custodiam.es"      "admin" "coordinador"
upsert_user "voluntario" "Volunt1234" "Maria" "Garcia"    "voluntario@custodiam.es" "voluntario"

echo
echo "==> Done. Test users are in place. Verify with:"
echo "    curl -G \"$KC_BASE/admin/realms/$REALM/users\" -H \"Authorization: Bearer \$ACCESS\""
