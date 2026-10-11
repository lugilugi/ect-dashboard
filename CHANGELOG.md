# Changelog

## Unreleased

### Backend (SQL schema 3, new fingerprint)

- Ingest resumes at once after a database restart. TimescaleDB 2.17 holds a
  job whose worker a PostgreSQL stop, restart or crash killed mid-run for at
  least 5 minutes (a fixed minimum that retry_period does not shorten). In
  3.0.0-rc.5 the single ingest_staged job could be caught that way, so SQL
  ingest stopped for about 5 minutes after such a restart; rows stayed staged
  or queued and nothing was lost. CI's Compose qualification hit this after its
  layout restart. Two identical jobs now share the ingest lock: only the holder
  can be caught mid-batch, the other takes over at once, and its first locked
  run replaces the held job with a fresh one. Qualification now pins an ingest
  run mid-batch, restarts the database and requires ingest within 60 s.
- schema.sql changed, so a database initialized by 3.0.0-rc.5 fails the new
  fingerprint check and is preserved. Reset it with the schema 3 steps in
  docs/implementation/cutover.md. The wire contract is unchanged.

## 3.0.0-rc.5 — 11 October 2026

- Removed the Config -> Throttle mapping screen. The app no longer sends
  CMD:THROTTLE_MAP; the ESP32 firmware must use a fixed default throttle curve
  (pending firmware-owner confirmation). Throttle_Percent remains a CAN reading,
  and the shared command, deadman and framing paths are unchanged.
- Removed the in-app driver alert system (audio, haptic and threshold alerts),
  its Config -> Alerts screen, the Android alert-cue channel and the VIBRATE
  permission. Saved alert preferences are cleared on first launch. Grafana
  server-side alert rules are unchanged.
- Phone upload path: the sender wakes on each journal commit and keeps sending
  while a backlog exists, with up to 8 envelopes awaiting PUBACK at once. Each
  round's acks and failures are written in one transaction, and a record is
  never in two envelopes at once. Reads are sized to fill the in-flight window,
  PUBACK waits grow with the queue, and reconnect backoff runs 1 s to 15 s.
- Phone journal: schema 5, migrated in place from 4 with pending records,
  watermarks and the checkpoint kept (no downgrade to rc.4 afterwards). Pending
  count, bytes and oldest record are kept in memory instead of rescanned.
  appendRecords returns a typed result: a full storage budget rejects only
  capture metrics (one aggregated Recording_Loss, identities consumed), while
  session metadata and control events (lap, recovery, loss) are always stored.
  Conflicting records go to a new journal_failed table, shown as FAILED RECORDS
  in storage health. The recorder commits every 200 ms or at 250 queued
  records, and recording resumes when the backlog drains instead of stalling.
- Broker and server CSV: Mosquitto queues are bounded by bytes (1.5 GB per
  client, set by max_queued_bytes in ops/backend/mosquitto.conf) and autosave
  every 30 s. The server CSV logger acknowledges a message only after its rows
  are fsynced. The Compose broker can now write its persistence volume; before,
  queued messages did not survive a broker restart in that layout.
- Housekeeping: ignore Python bytecode in git and Docker contexts, and set the
  package description. Telemetry event and session JSON are unchanged.

### Backend (SQL schema 3, clean server reset)

- Ingest: Telegraf now writes plain TEXT staging tables. A TimescaleDB job runs
  every second and validates and merges them in one set-based pass. This
  replaces the per-row triggers and their savepoint per record. Dedup,
  conflict diagnosis, revision ordering and quarantine are unchanged. The job
  also maintains latest-signal and session-bounds tables, so Grafana alerts
  and session discovery no longer scan telemetry history.
- Analytics: per-second and per-lap speed, power and accumulator figures now
  use original observations only (no sampler snapshots). They are
  time-weighted, holding each value until the next observation, capped at
  freshness. Dashboard signal plots use observation time. Power, distribution
  and coasting panels read the shared telemetry_seconds model.
- Grafana: alert rules read a new latest_session view built from the two small
  session tables. A new session whose metadata is still in transit is watched
  from its first samples. Panel and alert queries compare session_uid as a
  UUID, so indexes are used. Lap averages, shares and distributions are
  weighted by the time each second was actually covered.
- Ingest never inserts an already stored identity, so mixed batches and gap
  repairs into compressed chunks cannot drop rows; any count mismatch rolls the
  batch back and leaves it staged.
- Storage: compression after 2 days (was 2 hours), plus a lap-crossing partial
  index.
- The wire contract (ect.telemetry.v2) is unchanged, so phone and server can be
  upgraded independently. Existing schema-2 volumes are preserved and reported
  unhealthy. Follow the schema 3 steps in docs/implementation/cutover.md.

## 3.0.0-rc.4 — 10 October 2026

- Added Bluetooth LE as a selectable vehicle link on Android (Config ->
  Connectivity -> VEHICLE LINK: USB | BLE). The ESP32-C3 uses the Nordic UART
  service with passkey pairing; the link reconnects on its own while paired.
- USB on Android and desktop serial are unchanged and remain the default.
  Telemetry, commands, server and schema are unchanged.
- The ESP32 firmware must implement docs/implementation/ble-link.md before BLE
  mode can be used. BLE hardware qualification is pending.

## 3.0.0-rc.3 — 7 October 2026

- Replaced the CARTO tiles requiring API keys with OpenStreetMap in both Driver
  and Service maps. No map-provider account or key is needed.
- Added visible, linked attribution and disk caching that respects HTTP expiry.
  Only visible tiles are requested; both themes share downloads, with dark
  styling applied locally. GPS, recording and server contracts are unchanged.

## 3.0.0-rc.2 — 7 October 2026

- Fixed Android journal initialization: the WAL pragma returns a row and must use
  SQLite's query API. Recording can initialize without the top-bar database error.
- Added a mobile sqflite API regression backed by real SQLite, covering startup
  and preservation of pending records across reopening. No new schema reset.

## 3.0.0-rc.1 — 6 October 2026

- Implemented a clean-reset version-2 telemetry pipeline. Phone/server must ship
  as a qualified pair; old telemetry is not migrated.
- One-time phone format reset preserves connection, USB, GPS and UI preferences.
- Prerelease for qualification; hardware readiness and production cutover remain pending.

- Unified Docker inputs/roles, CSV downloads and shared replay-safe SQL analytics.
- One durable journal/sender replaces legacy spool/checkpoint/batch DTO paths.
- Fresh-source snapshots, explicit recording loss and unavailable temperatures.
