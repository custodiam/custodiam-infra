# justfile — atajos para los modos del stack y operaciones frecuentes.
#
# Requiere: just 1.40+ (cualquier versión moderna sirve).
#   winget install Casey.Just         # Windows
#   brew install just                  # macOS
#   cargo install just                 # cualquier sistema con Rust
#
# Lista todas las recetas disponibles con su descripción:
#   just                          # alias del default → `just --list`
#   just --list                   # explícito
#   just -l                       # forma corta
#
# Ver el cuerpo de una receta antes de ejecutarla:
#   just --show prod
#
# Las recetas no sustituyen a los scripts: cada una invoca el `.sh`
# correspondiente. Esto mantiene la compatibilidad con miembros del
# equipo que no usen just — los scripts siguen siendo el contrato.

# Receta por defecto al ejecutar `just` sin argumentos: lista todo.
default:
    @just --list

# Levantar el stack de DESARROLLO local (puertos al host, hot reload, sin túnel)
dev:
    ./scripts/dev-up.sh

# Levantar el stack en modo TUNNEL (staging vía Cloudflare, sin endurecer)
tunnel:
    ./scripts/tunnel-up.sh

# Levantar el stack en modo PRODUCCIÓN (tunnel + KC_HOSTNAME_STRICT=true + DEBUG=false)
prod:
    ./scripts/prod-up.sh

# Bajar el stack (los volúmenes nombrados sobreviven)
down:
    ./scripts/down.sh

# Forzar build sin cache de un servicio y recrear su contenedor. Útil
# cuando se sospecha que la layer cache de Docker se ha quedado podrida
# (síntoma típico: el contenedor arranca pero falla con ModuleNotFoundError
# o equivalente tras haber actualizado pyproject.toml / Dockerfile). El
# parámetro `service` por defecto es `api`; usa `just rebuild web` para
# el frontend.
rebuild service="api":
    docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml \
      build --no-cache {{service}}
    docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml \
      --profile dev up -d --force-recreate --no-deps {{service}}

# Sembrar las 7 cuentas de test (vol1, jefe1, coord1, tesor1, admin, reviewstore, superadmin) en el realm de DESARROLLO
seed:
    ./scripts/seed-test-users.sh

# Sembrar las 7 cuentas en el realm de PRODUCCIÓN (auth.custodiam.es). El script lee KEYCLOAK_PASSWORD de docker/.env.sops (sops+age) o docker/.env automáticamente, igual que dev-up.sh y prod-up.sh.
seed-prod:
    COMPOSE_OVERRIDE=docker/docker-compose.prod.yml \
    KC_BASE=https://auth.custodiam.es \
    ./scripts/seed-test-users.sh

# Ver los logs del servicio Keycloak (Ctrl+C para salir)
logs-keycloak:
    docker logs -f custodiam-auth

# Ver los logs del servicio API (Ctrl+C para salir)
logs-api:
    docker logs -f custodiam-api

# Ver los logs del túnel Cloudflare (Ctrl+C para salir)
logs-tunnel:
    docker logs -f custodiam-tunnel

# Ver el estado de todos los contenedores del proyecto
status:
    @docker ps --filter "label=com.docker.compose.project=custodiam" --format "table {{{{.Names}}\t{{{{.Status}}\t{{{{.Ports}}"
