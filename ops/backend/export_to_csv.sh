#!/bin/sh
# export_to_csv.sh — server-side CSV export for the ECT backend.
#
# Writes timestamped CSV dumps of the core tables into $EXPORT_DIR, so each
# run keeps a history instead of overwriting. Runs entirely on the server
# (inside the container), no host psql needed.
#
# Single container:      docker exec ect-backend export_to_csv.sh
# Compose stack:         docker exec ect-timescaledb sh /db/scripts/export_to_csv.sh
#
# Resulting files land in $EXPORT_DIR (single container: persistent volume
# /var/lib/ect-backend/exports, browsable at http://<host>:8080/; compose:
# bind-mounted host folder). Custom exports:
#   docker exec ect-backend psql -U postgres -d telemetry \
#     -c "\copy (SELECT * FROM telemetry_raw WHERE signal_name='Speed_Kmh') TO STDOUT WITH CSV HEADER"

set -e

# Connection defaults come from libpq env vars (PGHOST/…) with TS_* and
# plain defaults as fallbacks. 127.0.0.1 avoids unix-socket peer auth.
DB_HOST="${PGHOST:-${TS_HOST:-127.0.0.1}}"
DB_PORT="${PGPORT:-${TS_PORT:-5432}}"
DB_NAME="${PGDATABASE:-${TS_DB:-telemetry}}"
DB_USER="${PGUSER:-${TS_USER:-postgres}}"
export PGPASSWORD="${PGPASSWORD:-${TS_PASSWORD:-postgres}}"

EXPORT_DIR="${EXPORT_DIR:-/exports}"
mkdir -p "$EXPORT_DIR"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TABLES="sessions laps telemetry_raw"

echo "Exporting to $EXPORT_DIR (stamp $STAMP)"
for t in $TABLES; do
  out="$EXPORT_DIR/${t}_${STAMP}.csv"
  tmp="$out.tmp.$$"
  if ! psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" \
    -c "\copy (SELECT * FROM $t) TO STDOUT WITH CSV HEADER" > "$tmp"; then
    rm -f "$tmp"
    echo "Export failed for $t; no partial file left behind." >&2
    exit 1
  fi
  mv -f "$tmp" "$out"
  echo "wrote $out ($(wc -c < "$out") bytes)"
done
echo "Done."
