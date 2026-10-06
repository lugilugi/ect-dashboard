# Changelog

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
