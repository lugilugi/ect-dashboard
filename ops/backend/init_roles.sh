#!/bin/sh
set -eu
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1   --set=schema_hash="$(sha256sum /docker-entrypoint-initdb.d/01_schema.sql | cut -d' ' -f1)" --set=db="$POSTGRES_DB" --set=ingest_password="${TELEGRAF_PASSWORD:-telegraf}"   --set=reader_password="${GRAFANA_READER_PASSWORD:-grafana}" -f /etc/ect/bootstrap_roles.sql
