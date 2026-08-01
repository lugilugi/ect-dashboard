# =============================================================================
# ECT Dashboard - Single-container telemetry backend
#
# TimescaleDB (PostgreSQL) + Mosquitto (MQTT broker) + Telegraf (ingest)
# + Grafana (dashboards) in ONE image, orchestrated by supervisord.
#
# Base: postgres:16-bookworm (Debian) + TimescaleDB from the official
# Timescale Debian repo. Mosquitto comes from Debian, Telegraf from the
# InfluxData repo, Grafana from the Grafana repo - every component from its
# official source, one distro, no distro mixing.
#
# Build (from the repository ROOT - the whole repo is the build context):
#   docker build -t ect-backend -f ops/backend/Dockerfile .
#
# Run:
#   docker run -d --name ect-backend \
#     -p 1883:1883 -p 5432:5432 -p 3000:3000 \
#     -e POSTGRES_PASSWORD=changeme \
#     -e GRAFANA_ADMIN_PASSWORD=changeme \
#     ect-backend
#
# Every setting is overridable via environment variables (-e ...).
# See BACKEND_GUIDE.md for the full reference and the CAN signal how-to.
# =============================================================================
FROM postgres:16-bookworm

# --- TimescaleDB + base system packages --------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl \
       ca-certificates \
       gnupg \
       supervisor \
       mosquitto \
    && curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/timescale.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/timescale.gpg] https://packagecloud.io/timescale/timescaledb/debian/ bookworm main" \
        > /etc/apt/sources.list.d/timescaledb.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends timescaledb-2-postgresql-16 \
    && rm -rf /var/lib/apt/lists/*

# Preload the TimescaleDB extension on every new database (the postgres
# entrypoint copies this sample config into a fresh data dir on first boot).
RUN echo "shared_preload_libraries = 'timescaledb'" \
        >> /usr/share/postgresql/16/postgresql.conf.sample

# --- Telegraf (InfluxData apt repository) -------------------------------------
# influxdata-archive.key is the current signing key (fingerprint
# 24C975CBA61A024EE1B631787C3D57159FC2F927). Do NOT use the older
# influxdata-archive_compat.key - it expired 2026-01-17.
RUN curl -fsSL https://repos.influxdata.com/influxdata-archive.key \
        | gpg --dearmor -o /usr/share/keyrings/influxdata-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/influxdata-archive-keyring.gpg] https://repos.influxdata.com/debian stable main" \
        > /etc/apt/sources.list.d/influxdata.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends 'telegraf=1.31.*' \
    && rm -rf /var/lib/apt/lists/*

# --- Grafana (Grafana apt repository) -----------------------------------------
# Uses the latest Grafana from the apt repo. Grafana >=13 changed its default
# provisioning path to /usr/share/grafana/conf/provisioning, so our
# provisioning files live in a dedicated dir selected via GF_PATHS_PROVISIONING
# (see the runtime config below).
RUN curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/grafana-apt.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/grafana-apt.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends grafana \
    && rm -rf /var/lib/apt/lists/*

# --- runtime configuration -----------------------------------------------------
COPY ops/backend/supervisord.conf /etc/supervisor/conf.d/ect-backend.conf
COPY ops/backend/mosquitto.conf /etc/mosquitto/mosquitto.conf
COPY ops/backend/telegraf.conf /etc/telegraf/telegraf.conf
COPY ops/backend/export_to_csv.sh /usr/local/bin/export_to_csv.sh
COPY ops/backend/csv_server.py /usr/local/bin/csv_server.py
COPY db/schema.sql /docker-entrypoint-initdb.d/01_schema.sql
# Provisioning goes in a dedicated dir (not /etc/grafana/provisioning, which
# the package seeds with sample files) and is selected via GF_PATHS_PROVISIONING.
COPY ops/grafana/provisioning /etc/grafana/provisioning-ect
COPY ops/grafana/dashboards /var/lib/grafana/dashboards

RUN chmod +x /usr/local/bin/export_to_csv.sh \
    && chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning-ect

# --- default configuration (override any of these with `-e`) -------------------
ENV POSTGRES_DB=telemetry \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD=postgres \
    GRAFANA_ADMIN_USER=admin \
    GRAFANA_ADMIN_PASSWORD=admin \
    TOPIC_EVENTS=telemetry/eco_archers/events \
    TOPIC_SESSIONS=telemetry/eco_archers/sessions \
    MQTT_HOST=127.0.0.1 \
    MQTT_PORT=1883 \
    TS_HOST=127.0.0.1 \
    TS_PORT=5432 \
    TS_DB=telemetry \
    TS_USER=postgres \
    TS_PASSWORD=postgres \
    TS_DATASOURCE_URL=localhost:5432 \
    TS_DATASOURCE_USER=postgres \
    TS_DATASOURCE_DB=telemetry \
    TS_DATASOURCE_PASSWORD=postgres \
    EXPORT_DIR=/var/lib/ect-backend/exports \
    CSV_SERVER_PORT=8080 \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning-ect

VOLUME ["/var/lib/postgresql/data", "/var/lib/ect-backend/exports"]

EXPOSE 1883 5432 3000 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD pg_isready -U postgres -d telemetry || exit 1

CMD ["/usr/bin/supervisord", "-n"]
