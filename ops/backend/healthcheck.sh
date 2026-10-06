#!/bin/sh
set -eu
schema_hash=$(sha256sum /docker-entrypoint-initdb.d/01_schema.sql | cut -d' ' -f1)
export PGPASSWORD="$POSTGRES_PASSWORD"
[ "$(psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT schema_sha256 FROM schema_metadata')" = "$schema_hash" ]
mosquitto_pub -h 127.0.0.1 -t ect/healthcheck -m ok -q 1
wget -qO /dev/null http://127.0.0.1:3000/api/health
wget -qO /dev/null http://127.0.0.1:"$CSV_SERVER_PORT"/
for service in telegraf csv-streamer; do
  supervisorctl -c /etc/supervisord.conf status "$service" | grep -q RUNNING
done
