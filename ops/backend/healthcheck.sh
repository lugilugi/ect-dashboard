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
# Warn-only backlog alarm: never affects the exit status, because an unhealthy
# container would be restarted and could drop the queued data.
stored=$(mosquitto_sub -h 127.0.0.1 -t '$SYS/broker/messages/stored' -C 1 -W 3 2>/dev/null || true)
case "$stored" in
  ''|*[!0-9]*) ;;
  *) [ "$stored" -le "${QUEUE_WARN_MESSAGES:-50000}" ] || echo "WARN: broker stored messages $stored > ${QUEUE_WARN_MESSAGES:-50000}" >&2 ;;
esac
