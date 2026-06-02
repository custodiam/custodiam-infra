#!/usr/bin/env bash
#
# Internal helper sourced by dev-up.sh and tunnel-up.sh.
#
# Resolves which env file `docker compose --env-file` should consume:
#   1. docker/.env.sops    decrypted on the fly to a temp file (preferred).
#   2. docker/.env         used directly (fallback while transitioning).
#
# Sets the global ENV_FILE to the path that should be passed to compose.
# The caller MUST have CLEANUP_FILES=() declared and an EXIT trap that
# removes any temp files appended to that array. Example:
#
#   CLEANUP_FILES=()
#   trap '[[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}"' EXIT INT TERM
#   source "$(dirname "$0")/_lib-env.sh"
#   resolve_env_file
#   docker compose --env-file "$ENV_FILE" ...

resolve_env_file() {
  if [[ -f docker/.env.sops ]]; then
    if ! command -v sops >/dev/null 2>&1; then
      cat <<'ERR' >&2
ERROR: docker/.env.sops is present but sops is not installed.

Install via Git Bash on Windows:
  winget install SecretsOPerationS.SOPS FiloSottile.age

Then make sure your age private key lives at:
  ~/.config/sops/age/keys.txt

See guía 04 (gestión de secretos) for the full onboarding flow.
ERR
      exit 1
    fi
    ENV_FILE="$(mktemp)"
    CLEANUP_FILES+=("$ENV_FILE")
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
      sops -d --input-type dotenv --output-type dotenv docker/.env.sops > "$ENV_FILE"
  elif [[ -f docker/.env ]]; then
    ENV_FILE="docker/.env"
  else
    echo "ERROR: neither docker/.env.sops nor docker/.env exists." >&2
    echo "       See guía 04 (gestión de secretos) to bootstrap your local copy." >&2
    exit 1
  fi
}

# Decrypts the Firebase FCM service-account credential from its sops-encrypted
# form to the plaintext file that docker-compose.prod.yml bind-mounts into the
# api container. Unlike the env file (a temp file consumed via --env-file), the
# JSON must persist on disk while the detached container runs, so it is written
# to a gitignored path (NOT a temp file). No-op if the encrypted credential is
# absent (FCM simply stays disabled). sops is already guaranteed present by the
# time this runs (resolve_env_file exits earlier if it is missing).
decrypt_fcm_secret() {
  local enc=docker/secrets/fcm-service-account.sops.json
  local out=docker/secrets/fcm-service-account.json
  [[ -f "$enc" ]] || return 0
  SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
    sops -d --input-type json --output-type json "$enc" > "$out"
  chmod 600 "$out" 2>/dev/null || true
}
