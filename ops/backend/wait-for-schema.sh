#!/bin/sh
set -eu
schema_hash=$(sha256sum /docker-entrypoint-initdb.d/01_schema.sql | cut -d' ' -f1)
export PGPASSWORD="$TS_PASSWORD"
until psql -h "$TS_HOST" -p "$TS_PORT" -U "$TS_USER" -d "$TS_DB" -Atc   "SELECT schema_sha256 FROM schema_metadata WHERE version=2 AND contract='ect.telemetry.v2'" 2>/dev/null | grep -qx "$schema_hash"; do
  sleep 1
done
exec "$@"
