# ECT Dashboard Concrete Implementation Plan

This plan translates the architecture into executable phases with strict gates.
It is aligned with:

1. `UI.md`
2. `REBUILD_PLAN.md`
3. `DB_REFERENCE.md`

## 1. Construction Rules

1. Preserve current in-cabin visual style unless a phase explicitly requires UI changes.
2. Keep Driver Mode as the default runtime mode.
3. Use canonical enums everywhere:
- `ui_mode`: `DRIVER`, `SERVICE`
- `session_state`: `IDLE`, `ARMED`, `LOGGING`, `ENDED`
4. Count laps only on valid geofence crossings with filters and deadzones.
5. Publish dual timestamps for each event:
- `ts_wall_utc`
- `ts_session_ms`
6. Treat local SQLite as edge spool only; TimescaleDB is canonical analytics storage.
7. Keep deterministic command TX behavior with dictionary version checks and ACK/NACK handling.
8. Support mid-session crash recovery and automatic resume when feasible.
9. Expose live connectivity health and spool backlog in Driver Mode.
10. Keep GPS acquisition reliable in Android foreground operation during ARMED and LOGGING.
11. Provide non-visual alert channels (audio/haptic) for important race events and critical faults.
12. Keep Driver UI changes additive to current layout and design language unless explicitly approved for broader redesign.

## 2. Delivery Strategy

1. Build in vertical slices from app state to MQTT payload to DB query.
2. Keep each phase shippable behind feature flags where possible.
3. Do not start a new phase until the previous phase gate passes.
4. Keep migration scripts and config files versioned in repo.

## 2A. Execution Status Snapshot (2026-04-17)

Current implementation status in this repository:

1. Completed:
- Phase 0 Contract Freeze and Scaffolding
- Phase 1 Session Lifecycle and Lap Counting Core
- Phase 1A GPS Runtime Reliability and Foreground Operation
- Phase 2 UI Wiring for Driver and Service Modes
- Phase 2A Driver Alert Channels (Audio/Haptic)
- Phase 3 Event Pipeline and MQTT Batching
- Phase 3A Bi-Directional Command and Control TX
- Phase 4 Local Edge Spool (SQLite)
- Phase 4A Mid-Session Crash Recovery and Resume
- Phase 5 Backend Construction (Telegraf + TimescaleDB scaffolding)
- Phase 6 Grafana Construction (dashboards + provisioning scaffolding)

2. Partially complete:
- Phase 7 Hardening and Test Closure (suite now includes outage/replay, failover, crossing deadzone resistance, session transitions, checkpoint recovery, TX retry behavior, and critical alert latency/dedup checks; long-duration and hardware-only matrix items remain)

3. Pending:
- Phase 7 hardware endurance matrix closure (10-minute sustained replay, repeated physical USB reconnect cycles, and screen-off foreground soak on target Android hardware; execution checklist in `PHASE7_HARDWARE_RUNBOOK.md`)

4. Sequencing note:
- Backend and dashboard scaffolding work was delivered before Phase 2A to unblock pitwall setup and data-path validation.

## 3. Phase 0: Contract Freeze and Scaffolding

Goal:
- Freeze cross-document contracts into code types before behavior changes.

Tasks:
1. Add canonical enums in app code:
- `SessionState`
- `UiMode`
- `LapPhase`
2. Create contract models:
- `DecodedMetricEvent`
- `SessionControlState`
- `LapCrossingEvent`
3. Define one MQTT payload contract object for `telemetry/eco_archers/events`.
4. Add `schema_version` constant and contract version notes.

Expected file changes:
1. `lib/models/session_models.dart` (new)
2. `lib/models/telemetry_event.dart` (new)
3. `lib/services/mqtt_payload_contract.dart` (new)
4. `lib/providers/dashboard_state.dart` (minimal integration)

Gate to pass:
1. App compiles with new models/enums.
2. Existing UI still functions unchanged.
3. Unit tests validate enum and serialization round-trips.

## 4. Phase 1: Session Lifecycle and Lap Counting Core

Goal:
- Implement authoritative session state transitions and crossing-based lap counting.

Tasks:
1. Implement `SessionOrchestrator` service:
- state transitions `IDLE -> ARMED -> LOGGING -> ENDED`
- start gating on standstill precondition
- end gating on `lapsCompleted >= lapsPlanned` unless abort
2. Implement `LapBoundaryService`:
- line crossing detection from GPS samples
- heading filter
- speed threshold filter
- deadzone/debounce window
3. Emit structured `LapCrossingEvent` with:
- crossing candidate
- accepted/rejected reason
- confidence
4. Update `DashboardState` to consume orchestrator outputs.

Expected file changes:
1. `lib/services/session_orchestrator.dart` (new)
2. `lib/services/lap_boundary_service.dart` (new)
3. `lib/providers/dashboard_state.dart`
4. `lib/services/phone_gps_fallback_service.dart` (source metadata only)

Gate to pass:
1. Simulated crossing stream increments laps only on valid crossings.
2. Deadzone prevents duplicate lap count bursts.
3. Session cannot end normally before lap target.

## 5. Phase 1A: GPS Runtime Reliability and Foreground Operation

Goal:
- Ensure lap boundary logic receives stable, sufficiently frequent GPS updates even under Android lifecycle pressure.

Tasks:
1. Implement `GpsSourceManager` with explicit source arbitration:
- prefer external GPS when healthy
- fallback to phone GPS when external source is stale
- emit source-change events for UI and logs
2. Add high-rate location update profile:
- target 5 Hz where hardware supports it
- gracefully degrade when device limits apply
3. Implement Android foreground telemetry service for ARMED and LOGGING windows.
4. Define GPS freshness and confidence rules used by `LapBoundaryService`.
5. Upgrade simulator tooling to generate repeatable lap GPS paths for crossing test scenarios.

Expected file changes:
1. `lib/services/gps_source_manager.dart` (new)
2. `lib/services/phone_gps_fallback_service.dart`
3. `android/app/src/main/AndroidManifest.xml`
4. `android/app/src/main/kotlin/.../MainActivity.kt` or service runner file
5. `simulate_esp32.py`

Gate to pass:
1. GPS updates continue while screen is dimmed or app is backgrounded in active session.
2. Source failover external to phone and recovery back to external is visible and stable.
3. Lap boundary tests pass with replayed/simulated GPS trajectories.

## 6. Phase 2: UI Wiring for Driver and Service Modes

Goal:
- Surface the orchestrator state to UI without redesigning the visual language.

Tasks:
1. Update Driver Mode indicators:
- lap progress `x/y`
- crossing state indicator
- deadzone active indicator
2. Keep existing Driver layout and visual language, applying additive widget updates only.
3. Add telemetry connectivity and backlog indicators:
- USB status
- MQTT status
- unsent batch count
- oldest unsent age
4. Lock interactions while logging:
- config edits disabled
- service entry protected
5. Keep aux indicators always visible.
6. Keep single-tap path back to Driver Mode from Service Mode.

Expected file changes:
1. `lib/ui/dashboard_screen.dart`
2. `lib/providers/dashboard_state.dart`

Gate to pass:
1. Driver can complete full session flow from cab without hidden steps.
2. No accidental page-switch behavior in logging state.
3. Aux indicators remain visible and accurate.
4. Connectivity degradation is visible in Driver Mode within 1 second.
5. Backlog indicator clears to zero after reconnect replay completes.
6. Existing Driver visual language is preserved with only targeted additions.

## 7. Phase 2A: Driver Alert Channels (Audio/Haptic)

Goal:
- Add non-visual alert channels so critical events are perceivable without sustained visual focus.

Tasks:
1. Implement `DriverAlertService` with severity mapping and debounce:
- severity 1 advisory: optional soft cue
- severity 2 warning: audible cue + optional haptic
- severity 3 critical: distinct urgent cue + optional repeated cadence
2. Add event-to-alert mapping for:
- critical faults
- telemetry disconnect during LOGGING
- lap accepted cue
- lap rejected cue with reason class
3. Add cooldown and deduplication to prevent alert spam.
4. Add service-mode controls for alert volume, haptic enable, and test tone.

Expected file changes:
1. `lib/services/driver_alert_service.dart` (new)
2. `lib/providers/dashboard_state.dart`
3. `lib/ui/dashboard_screen.dart`
4. `pubspec.yaml` (if packages are required)

Gate to pass:
1. Severity 2 and 3 alerts trigger within defined latency budget.
2. No duplicate alert storm under repeated identical faults.
3. Lap accept/reject cues are clearly distinguishable in cabin testing.

## 8. Phase 3: Event Pipeline and MQTT Batching

Goal:
- Move from ad hoc metric publish to canonical batched event publish.

Tasks:
1. Replace single-metric publish calls with enqueue-to-buffer flow.
2. Flush in short windows and size-capped batches.
3. Include required fields per event:
- `session_id`
- `lap_number`
- `session_state`
- `lap_phase`
- `ts_wall_utc`
- `ts_session_ms`
- `metric_key`
- `metric_value`
- `source`
- `seq_in_session`
4. Enforce `seq_in_session` as strictly monotonic and unique per session for each decoded event.
5. Publish only to `telemetry/eco_archers/events`.

Expected file changes:
1. `lib/services/mqtt_service.dart`
2. `lib/services/usb_service.dart`
3. `lib/models/telemetry_event.dart`

Gate to pass:
1. MQTT packet rate drops significantly versus per-metric send.
2. No timestamp loss.
3. Event ordering preserved per session sequence.
4. No duplicate `seq_in_session` values are emitted within a session.

## 9. Phase 3A: Bi-Directional Command and Control TX

Goal:
- Implement deterministic, auditable app-to-ESP32 command delivery for allowed operations.

Tasks:
1. Create command dictionary model and versioning guard:
- command key
- command code
- arg schema
- safety class
2. Implement compact serial command encoder with CRC.
3. Implement ACK/NACK parser with timeout and retry budget.
4. Add idempotency guard for duplicate sequence responses.
5. Persist TX attempts and outcomes in local storage for auditability.

Expected file changes:
1. `lib/models/tx_can_command.dart` (new)
2. `lib/services/command_dictionary_service.dart` (new)
3. `lib/services/can_tx_service.dart` (new)
4. `lib/services/usb_service.dart`
5. `lib/providers/dashboard_state.dart`

Gate to pass:
1. Allowed valid command is encoded, sent, and ACKed successfully.
2. Invalid or unsafe command is blocked pre-send with explicit reason.
3. Timeout and retry behavior is deterministic and logged.

## 10. Phase 4: Local Edge Spool (SQLite)

Goal:
- Guarantee telemetry durability during network outages.

Tasks:
1. Add SQLite edge spool service.
2. Create edge spool tables:
- `raw_frames`
- `decoded_events`
- `publish_batches`
- `publish_attempts`
3. On publish failure, retain unsent batches.
4. On reconnect, replay unsent batches with idempotent keys.
5. Add spool retention and compaction policies:
- age-based cleanup for successfully published data
- size-based safety cap with explicit warning state

Expected file changes:
1. `lib/services/local_spool_service.dart` (new)
2. `lib/services/mqtt_service.dart`
3. `lib/main.dart` (lifecycle)

Gate to pass:
1. 2-5 minute broker outage yields zero data loss.
2. Replay succeeds and backlog drains in order.
3. Spool storage remains bounded by policy under long-run testing.

## 11. Phase 4A: Mid-Session Crash Recovery and Resume

Goal:
- Recover a previously active session after unexpected app termination with minimal data and state loss.

Tasks:
1. Add periodic session checkpoint snapshots:
- session_id
- session_state
- lap_number and lap_phase
- last seq_in_session
- last known source health
2. On app start, detect incomplete session termination and load checkpoint.
3. Resume orchestrator and sequence counters from checkpoint state.
4. Resume unsent MQTT replay before accepting normal end-of-session flow.
5. Emit explicit recovery diagnostic event for post-run audit.

Expected file changes:
1. `lib/services/session_checkpoint_service.dart` (new)
2. `lib/services/session_orchestrator.dart`
3. `lib/services/local_spool_service.dart`
4. `lib/main.dart`

Gate to pass:
1. Forced kill during LOGGING resumes with correct session and lap state.
2. Duplicate publish is prevented after recovery.
3. Recovery path is visible in diagnostics and test logs.

## 12. Phase 5: Backend Construction (Telegraf + TimescaleDB)

Goal:
- Stand up canonical relational/time-series model for session and lap analysis.

Tasks:
1. Add SQL migration files:
- `db/migrations/001_telemetry_schema.sql`
- `db/migrations/002_indexes_policies.sql`
2. Create tables and hypertables from `DB_REFERENCE.md`.
3. Add Telegraf config for MQTT batch parsing and DB writes.
4. Add source and quality mappings.

Expected repo additions:
1. `db/migrations/001_telemetry_schema.sql` (new)
2. `db/migrations/002_indexes_policies.sql` (new)
3. `ops/telegraf/telegraf.conf` (new)
4. `ops/mosquitto/` notes or sample config (new)
5. `db/migrations/003_command_and_recovery_audit.sql` (new)

Gate to pass:
1. Session-first query latency acceptable at target dataset size.
2. Lap drilldown query latency acceptable.
3. All required fields populated for 100% of logged events.
4. Command and recovery audit records are queryable by session.

## 13. Phase 6: Grafana Construction

Goal:
- Deliver usable session and lap analytics for race operations and post-run review.

Tasks:
1. Build dashboard variables:
- session selector
- lap selector scoped by session
2. Build panels:
- timeline by wall time
- lap overlays by session time
- crossing acceptance/rejection diagnostics
- run summary panel
3. Add operations panel for:
- connectivity state history
- MQTT backlog trend
- GPS source transitions
- command ACK/NACK outcomes
4. Validate fallback source visibility (external GPS vs phone GPS).

Expected repo additions:
1. `ops/grafana/dashboards/session_overview.json` (new)
2. `ops/grafana/dashboards/lap_analysis.json` (new)

Gate to pass:
1. Operators can select session then lap and retrieve correct data.
2. Lap overlays align on lap-relative time axis.
3. Operations panel makes link and recovery behavior diagnosable.

## 14. Phase 7: Hardening and Test Closure

Goal:
- Verify resilience under race-like load and edge failures.

Test suite:
1. High-rate replay for at least 10 minutes.
2. USB disconnect/reconnect recovery.
3. MQTT outage and replay.
4. GPS source failover and recovery.
5. Crossing false-positive resistance with deadzone.
6. Session state transition correctness.
7. Foreground service persistence through screen off and app background.
8. Mid-session crash/force-close recovery.
9. TX command ACK timeout and retry correctness.
10. Critical alert latency and dedup behavior.

Exit criteria:
1. No critical data loss.
2. No invalid lap increments under jitter.
3. No UI lockups under load.
4. Recovery and command paths are stable under repeated fault injection.

## 15. Risk Controls

1. Keep a feature flag for new lap counting path until validated.
2. Keep old publish path available behind toggle during rollout.
3. Log accepted/rejected crossings with reasons for auditability.
4. Enforce schema_version in payload parser.
5. Keep TX command path behind allowlist and safety-class gating.
6. Keep crash-recovery auto-resume behind feature toggle during rollout.
7. Keep audio/haptic alert channel configurable per event class.

## 16. Construction Order Summary

1. Phase 0
2. Phase 1
3. Phase 1A
4. Phase 2
5. Phase 2A
6. Phase 3
7. Phase 3A
8. Phase 4
9. Phase 4A
10. Phase 5
11. Phase 6
12. Phase 7

Do not reorder phases 1 through 4A, because UI and analytics integrity depend on the orchestrator and event contract being correct first.
