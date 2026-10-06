# Telemetry pipeline

The phone owns decoding, GPS selection, sessions/laps, commands and live display.
The recorder assigns immutable observation context before transport. SQLite is
the journal/outbox; one MQTT sender reads committed pending records.
PUBACK means broker receipt, never database delivery.

The server uses one version-2 contract: Mosquitto → Telegraf → validated SQL
ingest views → TimescaleDB → shared analytical views → Grafana.
Server MQTT-to-CSV capture stays independent of SQL. Local CSV is a restartable
export of committed journal records.

Driver and Service share the same runtime. Neither waits for SQL. Signals arrive
independently; each record owns its time, lap, source and quality. Adding a metric
does not require a database column.

See [the contract](../contracts/telemetry-v2.md),
[the decision](../decisions/0001-durable-telemetry-outbox.md), and
[the implementation gates](../implementation/backend-simplification.md).
