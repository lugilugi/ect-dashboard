# Both layouts use the same database, ingest and dashboard releases.
FROM telegraf:1.31.3 AS ingest
FROM grafana/grafana-oss:11.1.4 AS dashboards
FROM timescale/timescaledb:2.17.2-pg16
RUN apk add --no-cache supervisor tini mosquitto mosquitto-clients python3 py3-pip     libstdc++ ca-certificates wget  && python3 -m venv /opt/csv-runtime \
 && /opt/csv-runtime/bin/pip install --no-cache-dir paho-mqtt==2.1.0 \
 && addgroup -S ect && adduser -S -G ect ect  && addgroup -S grafana && adduser -S -G grafana grafana
COPY --from=ingest /usr/bin/telegraf /usr/bin/telegraf
COPY --from=dashboards /usr/share/grafana /usr/share/grafana
COPY ops/backend/supervisord.conf /etc/supervisord.conf
COPY ops/backend/mosquitto.conf /etc/mosquitto/mosquitto.conf
COPY ops/backend/telegraf.conf /etc/telegraf/telegraf.conf
COPY ops/backend/csv_streamer.py ops/backend/csv_server.py ops/backend/telemetry_contract.py ops/backend/export_snapshot.py /usr/local/bin/
COPY ops/backend/export_to_csv.sh ops/backend/wait-for-schema.sh ops/backend/healthcheck.sh /usr/local/bin/
COPY ops/backend/docker-entrypoint.sh /usr/local/bin/ect-entrypoint.sh
COPY db/schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY ops/backend/init_roles.sh /docker-entrypoint-initdb.d/02_roles.sh
COPY db/scripts/bootstrap_roles.sql /etc/ect/bootstrap_roles.sql
COPY ops/grafana/provisioning /etc/grafana/provisioning-ect
COPY ops/grafana/dashboards /var/lib/grafana/dashboards
RUN chmod +x /usr/local/bin/*.sh /docker-entrypoint-initdb.d/02_roles.sh  && mkdir -p /var/lib/ect-backend/exports /var/lib/mosquitto /var/lib/grafana  && chown -R grafana:grafana /var/lib/grafana
ENV POSTGRES_DB=telemetry POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres     GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD=admin     TELEGRAF_PASSWORD=telegraf GRAFANA_READER_PASSWORD=grafana     TELEGRAF_EVENTS_CLIENT_ID=ect-telegraf-events-v2-single     TELEGRAF_SESSIONS_CLIENT_ID=ect-telegraf-sessions-v2-single     CSV_CLIENT_ID=ect-csv-v2-single     TOPIC_EVENTS=telemetry/eco_archers/events     TOPIC_SESSIONS=telemetry/eco_archers/sessions     MQTT_HOST=127.0.0.1 MQTT_PORT=1883     EXPORT_DIR=/var/lib/ect-backend/exports CSV_SERVER_PORT=8080     GF_PATHS_PROVISIONING=/etc/grafana/provisioning-ect     GF_PATHS_DATA=/var/lib/grafana GF_PATHS_LOGS=/var/lib/grafana/log     GF_PATHS_PLUGINS=/var/lib/grafana/plugins GF_DASHBOARDS_DEFAULT_TIMEZONE=browser
VOLUME ["/var/lib/postgresql/data", "/var/lib/ect-backend/exports", "/var/lib/mosquitto", "/var/lib/grafana"]
EXPOSE 1883 5432 3000 8080
HEALTHCHECK --interval=15s --timeout=10s --start-period=60s --retries=5 CMD /usr/local/bin/healthcheck.sh
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/ect-entrypoint.sh"]
