# ECT dashboard

Flutter phone/desktop app plus two Docker layouts. Driver and Service share one
runtime; CAN DBC is protocol authority.

## Checks

After Dart changes run flutter pub get, flutter analyze --no-pub and
flutter test --no-pub. CI pins Flutter 3.41.5. Changes to the DBC also require
tools/generate_can_dart.py and committing the generated decoder.

For backend/contract changes run Python CSV tests and
tools/qualify_backend.py for BOTH layouts. It creates disposable test resources,
uses actual Dart capture/SQLite/MQTT, exercises SQL/CSV/Grafana and cleans up.
Real Android/CAN qualification is separate; read docs/implementation/verification.md
before calling a matching phone/server release qualified.

## Boundaries

Read docs/contracts/telemetry-v2.md when changing event fields, timing, identity,
recovery or delivery. Capture context belongs to TelemetryRecorder. Persistence
belongs to TelemetryJournal; transport reads committed records. Broker PUBACK is
handoff, not SQL durability. Keep command/deadman/USB framing behavior intact.
Hardware-dependent implementation decisions require hardware evidence.

Adding a signal changes dbc/network.dbc and can_bindings.dart, without a SQL
column. Preserve original source timestamps and GPS fix identity. Use shared SQL
read models in dashboards; delivery order and metadata arrival are unconstrained.

Read BACKEND_GUIDE.md when changing deployment/environment/schema/bootstrap.
Telegraf COPY tags remain TEXT in writable ingest views, while owned tables are
typed. Do not restore json_v2 array timestamp_key on 1.31.3: it repeats the first
element's time. Grafana provisioning supports plain environment interpolation;
defaults belong to container wiring. Both layouts share versions and inputs.

Schema bootstrap is fresh-only. Startup checks version/artifact fingerprint;
existing volumes are preserved. Explicit clean cutover is documented in
docs/implementation/cutover.md. Destructive reset targets this application's
dedicated data and preserves unrelated configuration/deployments.

Local SDK caches and csv_exports/build are artifacts. Keep credentials and
keystores out of commits. Release tags publish signed Android APKs; tagging or
pushing requires explicit user authorization.
