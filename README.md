# Custodiam Infra

Infraestructura Docker y configuraciones para desplegar Custodiam.

## Inicio rápido

```bash
# Configurar
cp docker/.env.example docker/.env
# Editar docker/.env con tus passwords

# Levantar servicios
./scripts/setup.sh
```

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
