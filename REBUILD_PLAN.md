# ECT Dashboard Rebuild Plan

This document defines a flexibility-first and robustness-first rebuild for the telemetry dashboard that interfaces with ESP32 + CAN + MQTT + in-cabin driver UI.

## Guiding Principles
1. Preserve data fidelity: keep per-event receive time for graphing and replay.
2. Keep UI deterministic: rendering cadence is fixed, independent of CAN burst rate.
3. Stay extensible: adding a CAN ID should only require adding decoder metadata, not touching multiple modules.
4. Fail safely: network loss, USB loss, and app restarts should not lose critical telemetry.
5. Bound memory and I/O: every queue must be bounded with clear backpressure behavior.
6. Version contracts: telemetry payload schema and decoder registry must carry explicit versioning.
7. Prioritize driver comprehension: all run-critical values must be visible in one in-cabin view.

## Target Architecture (High Level)
1. Ingest layer: USB reader receives compact serial telemetry frames from ESP32 bridge.
2. Parse layer: isolate parses serial frame -> raw CAN frame / decoded event.
3. Decode layer: registry maps CAN ID to typed decode function.
4. Store layer: in-memory event store + latest-value cache.
5. UI layer: fixed-rate notifier for smooth rendering with single-screen driver-first layout.
6. Export layer: local durable log + batched MQTT publisher.
7. Control layer: validated TX command channel from UI to CAN.

## Driver-Only In-Cabin Constraints
1. Driver Mode is the default and only mode allowed while logging is active.
2. Driver Mode must show speed, instant efficiency, average efficiency, energy used, session timer, and primary fault state simultaneously.
3. Configuration and service tools are locked while logging.
4. Navigation that can hide critical run data is disabled while logging.
5. Driver alerts must include concise action guidance when applicable.
6. Auxiliary state indicators (left/right signal, headlights, wipers, horn, hazards, brake light) remain visible in Driver Mode.
7. Start session requires standstill precondition.
8. Each lap is counted from valid geofence crossings with filtering and deadzone rules.
9. End session normally requires lapsCompleted >= lapsPlanned, except emergency abort.
10. Driver Mode must expose USB and MQTT health plus unsent spool backlog while logging.
11. Severity 2 and 3 alerts must include a non-visual channel (audio and/or haptic).
12. Telemetry runtime must remain alive in Android foreground during ARMED and LOGGING.
13. Unexpected app restart during LOGGING should recover prior session context when checkpoint data is valid.
14. Driver UI changes should be additive to the existing in-cabin design language and layout unless explicit redesign approval is provided.

## Shared Contract Across Documents
1. UI behavior contract is defined in UI.md.
2. Persistence and analytics contract is defined in DB_REFERENCE.md.
3. This file defines implementation order and runtime responsibilities.
4. Canonical runtime ui_mode values are DRIVER and SERVICE.
5. Canonical session_state values are IDLE, ARMED, LOGGING, ENDED.
6. Canonical MQTT topic for decoded event batches is telemetry/eco_archers/events.

## Core Data Contracts

### RawCanFrame
- Required fields: canId, payloadHex, dlc, receivedAtUsMono, receivedAtMsUtc, source.
- Purpose: canonical record for local logging and debug.

### DecodedMetricEvent
- Required fields: metricKey, value, unit, sessionId, lapNumber, tsWallUtc, tsSessionMs, source, canId, seqInSession, qualityFlag, receivedAtUsMono.
- Purpose: analytics, graphing, and MQTT export.

### SessionControlState
- Required fields: sessionState, uiMode, lapsPlanned, lapsCompleted, lapPhase, crossingDeadzoneMs, crossingDeadzoneRemainingMs, crossingValid.
- Purpose: authoritative lap counting behavior and driver gating logic.

### TxCanCommand
- Required fields: commandKey, args, targetCanId, issuedAtMsUtc, source, safetyTag.
- Purpose: normalized app-to-CAN command path.

## Serial Protocol (Compact, Dictionary-Based)
1. Use a shared command dictionary in app and firmware:
	- commandKey (for example HEADLIGHTS_TOGGLE)
	- commandCode (small int)
	- arg schema (count, type, min, max)
	- targetCanId and payload builder in firmware
2. App sends short framed serial commands, not candump strings.
3. Suggested wire format (ASCII compact):
	- TX: C|v1|seq|cmd|arg0|arg1|crc\n
	- ACK: A|v1|seq|ok|err|crc\n
4. Optional binary framing for even shorter packets after validation:
	- start byte, version, seq, cmd, args, crc16
5. ESP32 owns CAN packing details; app stays dictionary-driven.
6. Unknown commandCode or bad crc returns NACK and is logged.

## Flexibility Design (Adding New CAN IDs)
1. Use a registry object, not switch blocks:
	- canId
	- decode function
	- output metric keys
	- expected rate hint
	- optional validation bounds
2. Unknown IDs are preserved as raw frames and still logged locally.
3. Decoder errors do not kill the stream; they increment error counters and continue.
4. Feature flags can enable or disable specific decoders at runtime.
5. For TX commands, add one dictionary entry instead of hand-writing ad hoc serial strings.

## Robustness Design (Queues, Timing, Recovery)
1. Use bounded queues:
	- parse queue
	- decode queue
	- mqtt batch queue
	- local write queue
2. Define backpressure policy per queue:
	- drop-oldest for UI-only cache
	- never-drop for local durable log (until disk full handling triggers)
3. Keep both timestamps:
	- monotonic for ordering and local graphs
	- UTC wall time for cross-system joins
4. On startup, recover unsent local batches and retry publish.
5. On shutdown, flush queues with timeout and commit final local checkpoint.
6. Persist periodic session checkpoints (session id, lap number, lap phase, sequence) during LOGGING.
7. On unexpected restart, restore checkpoint and resume sequence allocation without duplication.
8. Bound spool growth with age and size policies plus warning thresholds.

## MQTT Strategy (Flexible Rate, Preserved Timing)
1. Keep each decoded event with its original receive timestamp.
2. Batch by short window (for example 100-250 ms) and size cap (for example 32-64 KB).
3. Publish an array of events in one message to reduce packet overhead.
4. Publish to telemetry/eco_archers/events.
5. Add batch metadata:
	- batchId
	- schemaVersion
	- createdAtMsUtc
	- sequence range
6. Include session_id, lap_number, ts_wall_utc, ts_session_ms, source, and seq_in_session on each event.
7. Keep seq_in_session strictly monotonic and unique within each session.
8. Use retry with exponential backoff and jitter.
9. Keep a local unsent spool if broker is offline.

## GPS Runtime Reliability Strategy
1. Add source arbitration manager (external GPS preferred, phone fallback).
2. Target high-rate updates where supported and degrade gracefully when limited by hardware.
3. Mark GPS source transitions in state and exported diagnostics.
4. Run telemetry GPS acquisition under Android foreground service during active session windows.
5. Provide deterministic replay/simulator path for geofence crossing validation.

## Driver UX Flow (Authoritative)
1. App boot:
	- Enter DRIVER mode in IDLE session_state.
	- Show all run-critical values with stale indicators where needed.
2. Session setup:
	- Driver confirms run name and lap target, then transitions to ARMED.
	- Service controls remain available only before LOGGING.
3. Session start preconditions:
	- Speed is at or below stop threshold.
	- Standstill stability window is satisfied.
	- Start is blocked until preconditions are true.
4. Session start:
	- Transition to LOGGING.
	- Lock configuration and service editing controls.
	- Disable navigation that can hide critical metrics.
5. Active run:
	- Decode and render telemetry with fixed-rate UI updates.
	- Emit batched events with dual timestamps.
	- Assign lap boundary via geofence and persist confidence.
	- Apply crossing filters and deadzone/debounce rules.
	- Increment lap count only on valid crossings.
	- Keep auxiliary indicators visible at all times.
	- Keep USB, MQTT, and backlog indicators visible with clear degraded states.
	- Emit non-visual cues for lap accept/reject and critical alerts.
6. Session stop:
	- Require target laps complete, except emergency abort.
	- Transition to ENDED.
	- Flush local and network queues.
	- Persist final session and lap summaries.
7. Post-run review:
	- Allow SERVICE mode tools for diagnostics and configuration.
	- Preserve DRIVER mode one-tap return.

## Lap Orchestration (Runtime)
1. Introduce SessionOrchestrator service as a single authority for:
	- session_state transitions
	- lap phase transitions
	- standstill and crossing validity checks
2. Canonical lap_phase values:
	- PRESTART_CHECK
	- RUNNING
	- CROSSING_CANDIDATE
	- CROSSING_DEADZONE
	- RESTART_ALLOWED
	- LAP_COMPLETE
	- SESSION_COMPLETE
3. Inputs to SessionOrchestrator:
	- speed stream
	- geofence crossing events
	- session control actions (arm, start, stop, abort)
4. Outputs from SessionOrchestrator:
	- session and lap state updates for UI
	- lap counting events for DB
	- crossing validity flags for end-session gating

## Local Backup Strategy
1. Prefer SQLite over CSV for durability and queryability under high event rate.
2. Suggested tables:
	- raw_frames
	- decoded_events
	- publish_batches
	- publish_attempts
3. Store publish state per event or per batch to support replay after reconnect.
4. Add retention policy (time-based and size-based) and compaction task.
5. These local tables are edge spool/cache tables and are intentionally separate from the Timescale canonical schema documented in DB_REFERENCE.md.

## UI Performance Strategy
1. Split state:
	- TelemetryRealtimeState (high rate)
	- SessionState (low rate)
	- ConfigState (rare updates)
2. Replace top-level watchers with fine-grained Selector usage.
3. Use fixed-rate notify loop (for example 30-60 Hz) while telemetry ingestion remains event-driven.
4. Keep expensive transforms out of build methods.

## Bi-Directional CAN Command Strategy
1. Route all UI commands through a dictionary-backed command encoder.
2. Encode commands to compact serial frames (not candump-style text).
3. Validate each command against allowlist and field bounds before send.
4. Require ack/timeout handling with retry budget and idempotency guard.
5. Log each TX command locally with commandKey, args, seq, and result status.
6. Enforce dictionary version compatibility check between app and firmware.
7. Differentiate NACK categories (validation, safety, transport) for operator diagnostics.
8. Keep non-emergency command actuation disabled in Driver Mode while logging.

## Safety and Validation Rules
1. Decoder validation: reject malformed payload length.
2. Metric validation: clamp or flag out-of-range values.
3. Command validation: block unsafe command payloads and unknown command IDs.
4. Protocol validation: reject bad crc, duplicate seq outside window, and stale ack.
5. Integrity checks: detect monotonic timestamp regressions and sequence gaps.

## Observability and Diagnostics
1. Track counters and expose in engineer view:
	- rxFramesPerSec
	- decodeErrors
	- droppedUiEvents
	- mqttQueueDepth
	- localWriteLatency
 	- unsentBatchCount
 	- oldestUnsentAgeMs
 	- gpsSourceTransitions
 	- commandAckRate
 	- commandTimeouts
 	- recoveryResumeCount
2. Add rotating logs for parser, MQTT, storage, and command channels.
3. Add health state machine (green/yellow/red) for USB, MQTT, storage.

## Incremental Execution Plan

### Phase 1: Introduce Contracts and Registry
- Create RawCanFrame, DecodedMetricEvent, TxCanCommand models.
- Implement CAN decoder registry and move existing decoders into it.
- Exit criteria: existing IDs decode correctly using registry only.

### Phase 2: Isolate Parsing Pipeline
- Move line parsing and hex conversion into isolate.
- Keep main thread handling only decoded outputs.
- Exit criteria: no visible UI stutter under replayed high-rate data.

### Phase 3: State Split + UI Selector Migration
- Split provider state into realtime/session/config domains.
- Replace broad watchers with selectors in critical widgets.
- Add Driver Mode connectivity badges and backlog visibility.
- Exit criteria: stable frame rate under burst input and clear degraded connectivity signaling.

### Phase 3A: Driver Alert Channels
- Implement audio/haptic alert service with severity mapping and cooldown.
- Add distinct lap accepted and lap rejected cues.
- Exit criteria: critical alerts are perceivable without sustained visual focus and avoid alert spam.

### Phase 4: Batched MQTT with Preserved Event Time
- Implement event buffer with window + size flush rules.
- Include batch metadata and schema version.
- Exit criteria: fewer packets, no lost event timestamps.

### Phase 4A: Command and Control TX Path
- Implement dictionary version guard, compact encoder, ack/nack parser, and retry budget.
- Add persistent TX audit log with status timeline.
- Exit criteria: deterministic command results and operator-auditable command history.

### Phase 5: Local Durable Backup + Replay
- Add SQLite persistence for decoded events and batch states.
- Implement reconnect replay of unsent batches.
- Add periodic session checkpoints and restart recovery path.
- Add spool retention and compaction policy.
- Exit criteria: network outage test shows zero telemetry loss and forced-restart recovery restores active session state.

### Phase 6: TX Command Channel Hardening
- Execute failure-injection tests for timeouts, NACKs, and duplicate ACK frames.
- Validate safety-class gating in Driver versus Service modes.
- Exit criteria: deterministic command behavior and safety gating under fault conditions.

### Phase 7: Observability + Stress Tests
- Add counters, debug widgets, stress replay tests, and foreground-service lifecycle tests.
- Exit criteria: sustained high-rate ingest without crash, controlled spool growth, and reliable resume behavior.

## Acceptance Tests (Minimum)
1. High-rate replay: at least 10 minutes at expected peak frame rate.
2. Network drop: disconnect MQTT for 2-5 minutes, verify local backlog and successful replay.
3. USB disconnect/reconnect: auto-recovery without app restart.
4. New CAN ID onboarding: add one new decoder with no UI core refactor.
5. TX command safety: invalid command blocked, valid command acked and logged.
6. Dictionary drift test: app dictionary and firmware dictionary version mismatch is detected and reported.
7. Driver-only visibility test: all run-critical metrics are visible without page switches while logging.
8. Lockout test: service/config controls are inaccessible while logging.
9. Auxiliary indicator test: in Driver Mode, auxiliary indicators are visible, update correctly from incoming telemetry, and remain readable in bright conditions.
10. Dual timestamp test: each event has valid ts_wall_utc and ts_session_ms.
11. Session/lap attribution test: each event is queryable by session_id then lap_number.
12. Geofence quality test: lap detection method and confidence are persisted for each lap transition.
13. Start gating test: session cannot enter LOGGING unless standstill preconditions are satisfied.
14. Lap counting test: each lap completion occurs only on valid filtered crossings with deadzone/debounce.
15. End gating test: normal end is blocked until lapsPlanned is reached.

## Suggested First Implementation Slice
1. Build registry + contracts.
2. Keep current UI as-is, but route existing decode through registry.
3. Add simple in-memory event buffer and batch publisher with timestamps.
4. Then introduce local SQLite backup.

This order gives the fastest path to improved flexibility while minimizing regression risk.