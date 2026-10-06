# Matching version-2 cutover

Status: implementation and automated qualification; hardware/release gate pending.
Old data need not be migrated. Ordinary startup preserves data; reset is a
separately chosen operator action.

## Release gate

Build the matching APK with a configured Android SDK/signing setup. Keep the existing signing certificate and choose a build number greater than the installed APK (the release workflow uses github.run_number); neither is qualified on this host. Run the
real phone/CAN smoke test below and record commit, schema fingerprint, image
digests, input rate, backlog/latency and results. Resolve failures before
publishing a release/tag. Healthy containers or simulated CAN do not satisfy
this gate.

## Targeted reset

1. Stop old publishers and active recording.
2. Identify this application's dedicated DB/schema, broker persistence, CSV
   root and phone telemetry storage. Preserve unrelated DBs/topics/auth/UI prefs.
3. Discard only this application's telemetry/session data and subscriber sessions/
   queued or retained telemetry. A new dedicated volume set can provide isolation;
   preserve old volumes if a rollback snapshot is desired. Never globally prune.
4. Start fresh v2 schema/roles/consumers. Check fingerprint and actual probe
   ingestion, Grafana discovery and CSV download.
5. Install the matching phone build. Its SQLite v3-to-v4 telemetry reset runs
   once; connection/USB/GPS/UI prefs survive. Old CSV is not imported.
6. Start a session and reconcile phone CSV, server CSV and SQL. Separate old and
   new publishers. If qualification fails, stop recording and fix forward or
   choose another explicit paired reset; discarded data is not migrated back.

## Real phone/CAN smoke test (pending)

- Driver/Service switching, actual CAN IDs/units, USB reconnect/baud/simulation;
  recording and live display with SQL unavailable.
- GPS permissions, external source freshness, phone fallback and paired fixes.
- Start/end, distance/geofence laps, elapsed continuity and app restart;
  offline ending retains final metadata.
- Broker outage/replay and real journal/SQL/CSV reconciliation.
- Commands, ACK/NACK/timeout diagnostics, deadman and maintenance gating.
- Android foreground/background, force-stop/relaunch, screen/wakelock/shutdown;
  measure actual pre-commit/power-loss windows.
- Peak CAN rate, UI responsiveness, quota/storage growth/backlog/freshness on
  the target phone.

Record exact results in verification.md. No phone/CAN bridge was available;
the user explicitly left this hardware gate pending.
