#!/bin/sh
# Backup diário (pg_dump, formato custom) dos bancos do n8n e da recepcionista.
# Mantém BACKUP_RETENTION_DAYS dias. Copie a pasta ./backups para fora do servidor
# (armazenamento externo criptografado) — ver INSTALACAO.md.
set -eu
umask 077
while true; do
  NOW_H=$(date +%H)
  if [ "$NOW_H" -eq "${BACKUP_HOUR:-2}" ]; then
    STAMP=$(date +%Y%m%d-%H%M)
    for DB in $BACKUP_DATABASES; do
      pg_dump -Fc -d "$DB" -f "/backups/${DB}-${STAMP}.dump" && echo "backup ok: ${DB}-${STAMP}.dump"
    done
    find /backups -name '*.dump' -mtime "+${BACKUP_RETENTION_DAYS:-14}" -delete
    sleep 3700
  fi
  sleep 600
done
