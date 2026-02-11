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

| Servicio | Puerto | URL |
|----------|--------|-----|
| API (FastAPI) | 8000 | http://localhost:8000 |
| Swagger UI | 8000 | http://localhost:8000/docs |
| Keycloak | 8080 | http://localhost:8080 |
| Flutter Web | 3000 | http://localhost:3000 |
| ntfy | 8090 | http://localhost:8090 |
| PostgreSQL | 5432 | localhost:5432 |

## Repos relacionados

- [custodiam-app](https://github.com/custodiam/custodiam-app) — App Flutter
- [custodiam-api](https://github.com/custodiam/custodiam-api) — Backend FastAPI

## Licencia

AGPL-3.0 — Ver [LICENSE](./LICENSE)
