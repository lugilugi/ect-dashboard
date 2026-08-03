#!/bin/sh
# Runtime env wiring for the single-container backend.
#
# Maps the documented GRAFANA_ADMIN_* and POSTGRES_* overrides onto the
# variables Grafana and Telegraf actually read, so `docker run -e VAR=value`
# works without editing config files. Explicit TS_* overrides always win.

set -e

export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

export TS_USER="${TS_USER:-${POSTGRES_USER:-postgres}}"
export TS_PASSWORD="${TS_PASSWORD:-${POSTGRES_PASSWORD:-postgres}}"
export TS_DB="${TS_DB:-${POSTGRES_DB:-telemetry}}"

export TS_DATASOURCE_USER="${TS_DATASOURCE_USER:-${POSTGRES_USER:-postgres}}"
export TS_DATASOURCE_PASSWORD="${TS_DATASOURCE_PASSWORD:-${POSTGRES_PASSWORD:-postgres}}"
export TS_DATASOURCE_DB="${TS_DATASOURCE_DB:-${POSTGRES_DB:-telemetry}}"

exec /usr/bin/supervisord -n
