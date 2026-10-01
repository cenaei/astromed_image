#!/usr/bin/env bash
# AstroMed database backup — run daily via cron (as root):
#   0 2 * * * /srv/astromed/deploy/backup.sh
set -euo pipefail

DB_NAME=astromed
BACKUP_DIR=/backup
KEEP_DAYS=7

mkdir -p "$BACKUP_DIR"
stamp="$(date +%F_%H%M)"
pg_dump -U postgres "$DB_NAME" | gzip > "$BACKUP_DIR/astromed-$stamp.sql.gz"
find "$BACKUP_DIR" -name 'astromed-*.sql.gz' -mtime "+$KEEP_DAYS" -delete

echo "Backup OK: $BACKUP_DIR/astromed-$stamp.sql.gz"
