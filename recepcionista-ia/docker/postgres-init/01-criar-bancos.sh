#!/bin/sh
# Executado UMA vez, na primeira inicialização do volume do PostgreSQL.
# Cria bancos e usuários separados (n8n x dados da recepcionista) e aplica o schema.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE "$N8N_DB_USER" LOGIN PASSWORD '$N8N_DB_PASSWORD';
CREATE DATABASE "$N8N_DB_NAME" OWNER "$N8N_DB_USER";
CREATE ROLE "$RIA_DB_USER" LOGIN PASSWORD '$RIA_DB_PASSWORD';
CREATE DATABASE "$RIA_DB_NAME" OWNER "$RIA_DB_USER";
REVOKE ALL ON DATABASE "$RIA_DB_NAME" FROM PUBLIC;
REVOKE ALL ON DATABASE "$N8N_DB_NAME" FROM PUBLIC;
SQL
# Extensões exigem superusuário; o restante do schema pertence ao usuário da aplicação.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$RIA_DB_NAME" \
  -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS btree_gist;"
psql -v ON_ERROR_STOP=1 --username "$RIA_DB_USER" --dbname "$RIA_DB_NAME" -f /ria-database/schema.sql
echo "Bancos criados e schema da Recepcionista IA aplicado."
