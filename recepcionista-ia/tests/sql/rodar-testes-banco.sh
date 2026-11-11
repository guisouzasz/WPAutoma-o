#!/usr/bin/env bash
# Cria um banco descartável, aplica schema + seed demo e roda os testes SQL.
# Uso: PGHOST=... PGPORT=... PGUSER=... tests/sql/rodar-testes-banco.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${TEST_DB:-ria_test_$$}"
PSQL="psql -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null
trap '$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true' EXIT
$PSQL -d "$DB" -f database/schema.sql >/dev/null
$PSQL -d "$DB" -f database/seed-demo.sql >/dev/null
$PSQL -d "$DB" -f tests/sql/testes-banco.sql 2>&1 | sed 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /'
