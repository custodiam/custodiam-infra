# Custodiam Infra

Infraestructura Docker y configuraciones para desplegar Custodiam.

## Inicio rápido

```bash
# Configurar — opción A (recomendada): usar el .env.sops cifrado del repo.
# Requiere tener tu clave age privada en ~/.config/sops/age/keys.txt y la
# pública añadida en .sops.yaml. Ver la guía 04 (gestión de secretos) del
# repo privado de documentación para el setup completo.
# Los wrappers descifran .env.sops a un tempfile al arrancar, sin acción
# manual adicional.

# Configurar — opción B (fallback, sin sops): usar la plantilla plana.
cp docker/.env.example docker/.env
# Editar docker/.env con tus passwords (POSTGRES_PASSWORD, KEYCLOAK_PASSWORD, DOMAIN, ...)

# Levantar el stack en modo desarrollo local
./scripts/dev-up.sh

# Sembrar los usuarios de test del realm custodiam (admin + voluntario)
./scripts/seed-test-users.sh

# Bajar el stack (los volúmenes con datos se conservan)
./scripts/down.sh
```

## Gestión de secretos (sops + age)

El fichero `docker/.env.sops` es la fuente de verdad para entornos del equipo: vive **cifrado** en el repo con [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) (lista de destinatarios en `.sops.yaml`). El `.env` plano está gitignored y solo existe en la máquina del dev.

Los wrappers `dev-up.sh` y `tunnel-up.sh` detectan `.env.sops` automáticamente, lo descifran a un tempfile con `trap` de limpieza y lo pasan a compose vía `--env-file`. Si no existe, caen al `.env` plano como fallback.

Operaciones canónicas (más detalle en la guía 04):

```bash
# Rotar un secret
sops docker/.env.sops                 # abre editor, edita, guarda

# Añadir destinatario nuevo (otro dev)
# 1. Editar .sops.yaml y añadir la clave pública age
# 2. Re-cifrar reconociendo el nuevo destinatario
sops updatekeys docker/.env.sops

# Ver qué cambió entre commits
git log -p docker/.env.sops           # muestra qué claves cambian (valores cifrados)
```

## Scripts de operación

Wrappers finos sobre `docker compose` que encapsulan los flags y profiles correctos por modo. Idempotentes: pueden re-ejecutarse sin efectos secundarios.

| Script | Modo | Qué hace |
| --- | --- | --- |
| `dev-up.sh` | Desarrollo local | Aplica el override `docker-compose.dev.yml`: expone puertos al host, builds locales de `api`/`web` con hot reload, `KC_HOSTNAME=http://localhost:8080` para que el flujo de adb-reverse funcione. |
| `tunnel-up.sh` | Cloudflare Tunnel | Levanta el stack base sin override de dev: puertos internos, `KC_HOSTNAME=auth.${DOMAIN}`, `cloudflared` activo. Flag `--skip-images` para arrancar solo postgres + keycloak + cloudflared (útil si los pulls de GHCR fallan). |
| `down.sh` | — | Para y elimina todos los contenedores del proyecto independientemente del modo en que se levantaron (incluye los profiles `tunnel`, `full`, `test`). Flag `--volumes`/`-v` para wipe destructivo de volúmenes nombrados (`postgres_data`, `ntfy_data`, `n8n_data`) con confirmación interactiva. |
| `seed-test-users.sh` | — | Crea de forma idempotente los dos usuarios de test que la guía 10 §9 exige en el realm `custodiam`: `admin/Admin1234` (roles `admin` + `coordinador`) y `voluntario/Volunt1234` (Maria Garcia sin tilde, rol `voluntario`). Lee la credencial del realm master de `KEYCLOAK_PASSWORD` (variable env o `docker/.env`). Necesario después de un `down.sh --volumes` porque el realm export parcial no incluye usuarios. |

## Servicios

| Servicio | Puerto | URL | Profile |
|----------|--------|-----|---------|
| API (FastAPI) | 8000 | http://localhost:8000 | (default) |
| Swagger UI | 8000 | http://localhost:8000/docs | (default) |
| Keycloak | 8080 | http://localhost:8080 | (default) |
| Flutter Web | 3000 | http://localhost:3000 | (default) |
| ntfy | 8090 | http://localhost:8090 | (default) |
| PostgreSQL | 5432 | localhost:5432 | (default) |
| n8n | 5678 | http://localhost:5678 | `full` |
| Cloudflare Tunnel | — | — | `tunnel` |
| Mock OIDC server | 8888 | http://localhost:8888 | `test` |

### Mock OIDC server (testing del cliente OIDC)

Servicio opt-in para testar `KeycloakAuthService` y similares en `custodiam-app` sin Keycloak real ni navegador. No arranca por defecto. Ver [guía 22 §5](https://github.com/rodrigomulero/DOCUMENTACION) (repo privado del equipo) para el patrón completo.

```bash
# Arrancar solo el mock (no levanta postgres/keycloak/api/web/ntfy)
docker compose --profile test up -d mock-oidc

# Verificar
curl http://localhost:8888/default/.well-known/openid-configuration

# Bajarlo
docker compose --profile test down
```

## Repos relacionados

- [custodiam-app](https://github.com/custodiam/custodiam-app) — App Flutter
- [custodiam-api](https://github.com/custodiam/custodiam-api) — Backend FastAPI

## Licencia

AGPL-3.0 — Ver [LICENSE](./LICENSE)
