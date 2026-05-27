# Custodiam Infra

Infraestructura Docker y configuraciones para desplegar **Custodiam**, sistema multiplataforma de gestión para agrupaciones de Protección Civil.

📚 **Documentación completa:** <https://docs.custodiam.es>

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
# o, con just (interfaz preferida, recomendada): `just dev`

# Sembrar los usuarios de test del realm custodiam (admin + voluntario)
./scripts/seed-test-users.sh
# o con just: `just seed`

# Bajar el stack (los volúmenes con datos se conservan)
./scripts/down.sh
# o con just: `just down`
```

> **just como interfaz preferida (desde EN-08-31):** los scripts shell siguen siendo el **contrato canónico**, pero `just` los envuelve con atajos más cortos (`just dev`, `just tunnel`, `just prod`, `just down`, `just seed`, `just status`, `just logs-api`...). Instalación: `winget install Casey.Just` (Windows) · `brew install just` (macOS) · `cargo install just` (Linux). Ver `justfile` en la raíz del repo para el catálogo completo de recetas, o ejecutar `just --list`.

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
| `seed-test-users.sh` | — | Crea de forma idempotente las siete cuentas de test del realm `custodiam` (todas con password = username): `vol1` (voluntario), `jefe1` (jefe_equipo), `coord1` (coordinador), `tesor1` (tesorero), `admin` (admin técnico), `reviewstore` (coord + admin, credencial pública para Google Play / Apple) y `superadmin` (coord + admin, cuenta de emergencia del equipo). Las seis cuentas humanas tienen fila en `voluntarios` + asignación activa en `voluntario_roles`. Lee la credencial del realm master de `KEYCLOAK_PASSWORD` (variable env o `docker/.env`); parametrizable con `COMPOSE_OVERRIDE` para seedar contra `docker-compose.prod.yml` desde el host productivo. Necesario después de un `down.sh --volumes` porque el realm export parcial no incluye usuarios. |

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

## Más información

- **[docs.custodiam.es/empezar/infra](https://docs.custodiam.es/empezar/infra/)** — recorrido detallado de instalación con prerequisitos y troubleshooting.
- **[docs.custodiam.es/arquitectura](https://docs.custodiam.es/arquitectura/)** — diagrama de la topología de despliegue, modos dev/tunnel/prod, decisiones.
- **[docs.custodiam.es/adrs](https://docs.custodiam.es/adrs/)** — registro de decisiones (incl. Docker Compose, 2 BDs separadas, sops + age, tres modos de despliegue).

## Repos relacionados

- [custodiam-app](https://github.com/custodiam/custodiam-app) — App Flutter (Android + iOS + Web)
- [custodiam-api](https://github.com/custodiam/custodiam-api) — Backend FastAPI + SQLModel
- [custodiam-book](https://github.com/custodiam/custodiam-book) — Source del book de documentación pública

## Licencia

AGPL-3.0 — Ver [LICENSE](./LICENSE)
