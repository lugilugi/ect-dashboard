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

## Schema 3 server cutover (3.0.0-rc.5 backend)

Schema version 3 replaces the per-row INSTEAD OF ingest triggers with Telegraf
staging tables and the 1 s ingest_staged job, adds ingest-maintained
latest_signal_values/session_bounds, time-weighted observation-only analytics,
the latest_session view, a lap-crossing partial index and a 2-day compression
policy. The wire contract stays ect.telemetry.v2: phone builds, topics, event
and session JSON, identity/time and CSV are unchanged, so no phone reset or
reinstall is needed and phone/server may be upgraded independently.

Bootstrap stays fresh-only; there is no migration script (owner decision,
11 October 2026). An existing schema-2 volume fails the fingerprint check: the
new single container is unhealthy and its Telegraf waits, and Compose holds
Telegraf/Grafana behind the database health check. The volume is preserved and
never altered. To cut over:

1. Let the broker queue drain into SQL, or keep the phones' journals (7 days of
   ACKed history) and server CSV so missing rows can be replayed afterwards.
2. Optionally snapshot old data with the reader export (export_to_csv.sh or
   export_snapshot.py) and keep the old database volume for rollback.
3. Stop the stack. Point it at a new dedicated database volume, or remove only
   this application's database volume. Keep the Mosquitto volume so queued
   offline messages and persistent consumer sessions survive; keep Grafana and
   CSV volumes.
4. Start the new release. Check schema_metadata shows version 3 and the current
   fingerprint, ingest_status drains to 0, and the ingest_staged job reports no
   failures (db/scripts/verify_setup.sql prints both).
5. Re-ingest anything needed with tools/replay_csv.py from server or phone CSV
   (original identities and times are kept), then reconcile.

Rollback: stop the new stack and reattach the preserved schema-2 volume with the
previous release images.

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
