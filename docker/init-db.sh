#!/bin/bash
# init-db.sh — Crea bases de datos adicionales en el primer arranque
# Se ejecuta automáticamente via docker-entrypoint-initdb.d
# Solo se ejecuta si el volumen de datos está vacío (primera vez)

set -e

echo "🔧 Creando base de datos para Keycloak..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE ${KEYCLOAK_DB:-custodiam_kc}
        OWNER ${POSTGRES_USER}
        ENCODING 'UTF8'
        LC_COLLATE 'en_US.utf8'
        LC_CTYPE 'en_US.utf8';
EOSQL

echo "✅ Base de datos ${KEYCLOAK_DB:-custodiam_kc} creada"
