#!/bin/sh
set -eu
export PGPASSWORD="$TS_PASSWORD"
until psql -h "$TS_HOST" -p "$TS_PORT" -U "$TS_USER" -d "$TS_DB" -Atc   "SELECT version FROM schema_metadata WHERE version=2 AND contract='ect.telemetry.v2'" 2>/dev/null | grep -qx 2; do
  sleep 1
done
exec "$@"
