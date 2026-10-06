# Verification evidence

## Development baseline (6 October 2026)

- Main remains 5cdb2cc; implementation branch: codex/backend-clean-reset.
- Flutter 3.41.5 / Dart 3.11.3: 103 existing tests passed.
- Dependencies resolved from the existing lockfile; no dependency upgrades.
- Telegraf 1.31.3 Windows binary: events-array parsing preserves tags/value.
- Its object timestamp_key applies the first array timestamp to both fixture
  records. The adapter therefore carries ts_wall_utc as TEXT and casts each
  record's original timestamp in SQL; plugin gather time is receipt context only.

- TimescaleDB 2.17.2 / PostgreSQL 16.6 + Telegraf 1.31.3 + Mosquitto:
  actual MQTT â†’ COPY-to-view passed per-record time/lap, repeated identity,
  conflicting duplicate quarantine, telemetry-before-metadata, revision ordering
  and replay into a manually compressed chunk.
- CSV contract: four tests passed, including malformed neighbor isolation and
  duplicate archive identities after writer restart.

Broader container and phone-path checks remain pending subsequent stages.

## Capture and journal stages

- Capture/clock stage: 106 Flutter tests passed; changed-file analysis passed.
- Journal stage: dependency resolution, full analysis (no issues), and all 111
  Flutter tests passed.
- Five real-SQLite cases cover reopening, one-time format reset, quota identity
  protection, atomic ending metadata/checkpoint clear, and local CSV recovery
  after export failure with retention protection.
- RandomAccessFile flush replaces buffered IOSink flush for cursor advancement.

The new recorder/journal are integrated into the runtime in the sender stage.
Hardware qualification is pending by user instruction: no Android/CAN hardware
is available. Do not publish or declare a hardware-qualified release.

## Stage 05 — runtime and journal sender

CAN/USB and phone GPS now record through TelemetryRecorder, preserving original
observation time and paired fix identity. Recorder owns metadata revisions,
checkpoint recovery, bounded capture, fresh snapshots and journal writes.
MqttService only batches committed records and advances delivery on broker PUBACK.
There is no direct publish path, second replay queue, or implicit RAM fallback.
Ending a recovered session offline is allowed; final metadata and checkpoint
clearing share one transaction. Old batch DTO, spool and checkpoint modules and
their fake-storage tests were replaced by real SQLite journal/pipeline tests.
Capacity is bytes; storage/CSV errors are visible in the driver status.

Checks: flutter pub get, flutter analyze --no-pub (no issues), full flutter
test --no-pub: 87 passed. New tests verify restart sequence recovery, offline
completion, exact-context retry and ACK ownership. Command/deadman and existing
UI/GPS regressions pass. Fewer tests reflect removal of the retired fake spool
implementation; this is not a comparison of physical-device coverage.

## Stage 06 — deployment parity

Single image now reuses the exact Compose TimescaleDB 2.17.2/PG16, Telegraf
1.31.3 and Grafana 11.1.4 binaries instead of independent apt package streams.
Both layouts share Telegraf and Mosquitto configuration, bounded ingest/reader
roles, fresh-only role initialization, source contract version readiness and CSV
HTTP service. PostgreSQL readiness uses TCP, after temporary initialization.
Derived SQL read models are initialized with the owned schema and reader grants.
Paho uses its current v2 callback API; CSV processes drop to nobody in Compose.
Shell sources have LF line endings (the first Windows-context image exposed
a CRLF shebang failure, repaired before the successful startup).

Evidence: disposable single container with custom DB/user/passwords was healthy;
two MQTT records became two distinct SQL times; ingest view insert allowed while
direct raw-table insert denied; independent CSV output exists. Disposable Compose
with custom credentials ingested the same fixture and served its CSV over HTTP.
Final shared-image rebuild and restart/outage qualification remain stage 08.
No installed data volume or live deployment was changed.
