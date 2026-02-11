#!/bin/bash
# scripts/setup.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$INFRA_DIR/docker"

echo "🚀 Configurando Custodiam..."
echo ""

# ============ Verificaciones ============
echo "📋 Verificando requisitos..."

# Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker no está instalado"
    echo "   Instalar: https://docs.docker.com/get-docker/"
    exit 1
fi
echo "✅ Docker instalado"

# Docker Compose
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose no está instalado"
    exit 1
fi
echo "✅ Docker Compose instalado"

# .env
if [ ! -f "$DOCKER_DIR/.env" ]; then
    echo ""
    echo "📝 Creando .env desde .env.example..."
    cp "$DOCKER_DIR/.env.example" "$DOCKER_DIR/.env"
    echo ""
    echo "⚠️  IMPORTANTE: Edita $DOCKER_DIR/.env con tus valores"
    echo "   Especialmente: POSTGRES_PASSWORD y KEYCLOAK_PASSWORD"
    echo ""
    read -p "¿Has editado el archivo .env? (s/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Edita el archivo y vuelve a ejecutar este script."
        exit 1
    fi
fi
echo "✅ Archivo .env existe"

# Verificar repos hermanos (para dev)
APP_DIR="$INFRA_DIR/../custodiam-app"
API_DIR="$INFRA_DIR/../custodiam-api"

if [ -d "$APP_DIR" ] && [ -d "$API_DIR" ]; then
    echo "✅ Repos hermanos encontrados (modo desarrollo)"
    DEV_MODE=true
else
    echo "ℹ️  Repos hermanos no encontrados (usará imágenes GHCR)"
    DEV_MODE=false
fi

# ============ Levantar servicios ============
echo ""
echo "🐳 Levantando servicios..."

cd "$DOCKER_DIR"

if [ "$DEV_MODE" = true ]; then
    echo "   Modo: DESARROLLO (build local)"
    docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
else
    echo "   Modo: PRODUCCIÓN (imágenes GHCR)"
    docker compose -f docker-compose.yml up -d
fi

# ============ Esperar servicios ============
echo ""
echo "⏳ Esperando a que los servicios estén listos..."

# Esperar PostgreSQL
echo -n "   PostgreSQL: "
until docker compose exec -T postgres pg_isready -U custodiam &> /dev/null; do
    echo -n "."
    sleep 2
done
echo " ✅"

# Esperar Keycloak (puede tardar ~60s)
echo -n "   Keycloak: "
for i in {1..30}; do
    if curl -sf http://localhost:8080/health/ready &> /dev/null; then
        echo " ✅"
        break
    fi
    echo -n "."
    sleep 5
done

# Esperar API
echo -n "   API: "
for i in {1..10}; do
    if curl -sf http://localhost:8000/health &> /dev/null; then
        echo " ✅"
        break
    fi
    echo -n "."
    sleep 2
done

# ============ Resumen ============
echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✅ Custodiam iniciado correctamente!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Servicios disponibles:"
echo ""
echo "  📡 API:       http://localhost:8000"
echo "  📖 Swagger:   http://localhost:8000/docs"
echo "  🔐 Keycloak:  http://localhost:8080"
echo "  🌐 Web:       http://localhost:3000"
echo "  📢 ntfy:      http://localhost:8090"
echo ""
echo "  Credenciales Keycloak:"
echo "    Usuario: admin"
echo "    Password: (ver .env)"
echo ""
echo "  Comandos útiles:"
echo "    Ver logs:      cd docker && docker compose logs -f"
echo "    Parar:         cd docker && docker compose down"
echo "    Reiniciar:     cd docker && docker compose restart"
echo ""
