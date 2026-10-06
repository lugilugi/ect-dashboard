#!/bin/sh
set -eu
export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
export TS_HOST="${TS_HOST:-127.0.0.1}" TS_PORT="${TS_PORT:-5432}"
export TS_USER="${TS_USER:-telegraf_ingest}"
export TS_PASSWORD="${TS_PASSWORD:-${TELEGRAF_PASSWORD:-telegraf}}"
export TS_DB="${TS_DB:-${POSTGRES_DB:-telemetry}}"
export TS_DATASOURCE_URL="${TS_DATASOURCE_URL:-127.0.0.1:5432}"
export TS_DATASOURCE_USER="${TS_DATASOURCE_USER:-grafana_reader}"
export TS_DATASOURCE_PASSWORD="${TS_DATASOURCE_PASSWORD:-${GRAFANA_READER_PASSWORD:-grafana}}"
export TS_DATASOURCE_DB="${TS_DATASOURCE_DB:-${POSTGRES_DB:-telemetry}}"
mkdir -p "$EXPORT_DIR" /var/lib/mosquitto /var/lib/grafana
chown ect:ect "$EXPORT_DIR"
chown mosquitto:mosquitto /var/lib/mosquitto
chown grafana:grafana /var/lib/grafana
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
