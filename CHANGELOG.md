# Changelog

## Unreleased

- Implemented a clean-reset version-2 telemetry pipeline. Phone/server must ship
  as a qualified pair; old telemetry is not migrated.
- One-time phone format reset preserves connection, USB, GPS and UI preferences.
- Hardware qualification remains pending; this entry does not declare a release.

- Unified Docker inputs/roles, CSV downloads and shared replay-safe SQL analytics.
- One durable journal/sender replaces legacy spool/checkpoint/batch DTO paths.
- Fresh-source snapshots, explicit recording loss and unavailable temperatures.
