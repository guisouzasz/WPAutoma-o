#!/usr/bin/env bash
# Gera database/schema.sql (todas as migrações concatenadas) e database/seed-demo.sql.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- ARQUIVO GERADO por scripts/montar-schema.sh a partir de database/migrations/*.sql"
  echo "-- Para instalação nova: psql \"\$DATABASE_URL\" -f database/schema.sql"
  for f in database/migrations/*.sql; do echo; echo "-- >>> $f"; cat "$f"; done
} > database/schema.sql
{
  echo "-- ARQUIVO GERADO: dados FICTÍCIOS da clínica demo (config/clinica-exemplo.json)."
  echo "-- NÃO use em produção com pacientes reais."
  node scripts/gerar-sql-clinica.mjs config/clinica-exemplo.json
} > database/seed-demo.sql
echo "schema.sql e seed-demo.sql atualizados"
