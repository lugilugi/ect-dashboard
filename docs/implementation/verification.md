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
  actual MQTT → COPY-to-view passed per-record time/lap, repeated identity,
  conflicting duplicate quarantine, telemetry-before-metadata, revision ordering
  and replay into a manually compressed chunk.
- CSV contract: four tests passed, including malformed neighbor isolation and
  duplicate archive identities after writer restart.

Broader container and phone-path checks remain pending subsequent stages.
Hardware qualification is pending by user instruction: no Android/CAN hardware
is available. Do not publish or declare a hardware-qualified release.
