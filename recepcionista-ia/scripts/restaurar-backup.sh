#!/usr/bin/env bash
# Restaura um backup gerado pelo serviço "backup".
# Uso: scripts/restaurar-backup.sh backups/recepcionista-20261110-0200.dump recepcionista
# ATENÇÃO: substitui o conteúdo atual do banco informado. Pare o n8n antes: docker compose stop n8n
set -euo pipefail
ARQ="$1"; DB="$2"
[ -f "$ARQ" ] || { echo "arquivo não encontrado: $ARQ"; exit 1; }
read -r -p "Restaurar $ARQ sobre o banco $DB? Digite o nome do banco para confirmar: " C
[ "$C" = "$DB" ] || { echo "cancelado"; exit 1; }
docker compose exec -T postgres sh -c "pg_restore --clean --if-exists -U \"\$POSTGRES_USER\" -d \"$DB\"" < "$ARQ"
echo "Restaurado. Inicie o n8n: docker compose start n8n"
