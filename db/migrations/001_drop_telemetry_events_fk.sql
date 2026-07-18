-- Migration 001: Drop FK constraint from telemetry_events
--
-- WHY: The telemetry_events table had a FOREIGN KEY referencing telemetry.sessions.
-- Telegraf writes to both tables via separate independent MQTT consumers. Because
-- these consumers race, events almost always arrive at PostgreSQL before the session
-- row is committed. Every event batch was silently rejected by the FK check.
--
-- This constraint is an anti-pattern for streaming pipelines. Session integrity is
-- enforced at the application layer (the app always publishes session metadata before
-- starting to emit events).
--
-- Run this against your EXISTING database once. Safe to re-run (IF EXISTS).

ALTER TABLE telemetry.telemetry_events
  DROP CONSTRAINT IF EXISTS telemetry_events_session_id_fkey;
