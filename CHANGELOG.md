# Changelog

## 3.0.0-rc.1 — 6 October 2026

- Implemented a clean-reset version-2 telemetry pipeline. Phone/server must ship
  as a qualified pair; old telemetry is not migrated.
- One-time phone format reset preserves connection, USB, GPS and UI preferences.
- Prerelease for qualification; hardware readiness and production cutover remain pending.

- Unified Docker inputs/roles, CSV downloads and shared replay-safe SQL analytics.
- One durable journal/sender replaces legacy spool/checkpoint/batch DTO paths.
- Fresh-source snapshots, explicit recording loss and unavailable temperatures.
