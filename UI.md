# UI Guidance for ECT Dashboard (Shell Eco-marathon)

This document defines the target UI behavior for the rebuild.
It is focused on low cognitive load, race safety, and robust operation under high-rate telemetry.
This UI is in-cabin and is the only information source available to the driver during a run.

## 1. Product Goal
The UI exists to help the driver make better efficiency decisions during a run, not to expose every internal signal at all times.

Primary outcome:
- Driver can quickly see whether the car is on pace for best efficiency.

Competition constraint:
- Session starts from standstill.
- Laps are counted from valid geofence crossings.
- Crossing filters and deadzones prevent duplicate or false lap counts.
- Session ends when target lap count is reached or explicit abort is triggered.

Secondary outcomes:
- Faults are visible immediately.
- Session state is always unambiguous.
- Controls cannot be triggered accidentally.

## 2. Operation Modes (In-Cabin)
Use explicit modes with hard boundaries.

Canonical enums shared across docs:
- ui_mode: DRIVER, SERVICE
- session_state: IDLE, ARMED, LOGGING, ENDED

### Driver Mode (default, required during run)
Audience:
- Driver

Allowed:
- Read-only core telemetry
- Start/Stop session (with confirmation)
- Emergency-only actions

Blocked:
- Configuration edits
- Simulation toggles
- Endpoint edits
- Advanced command controls

### Service Mode (vehicle stopped, logging inactive)
Audience:
- Driver plus engineer during setup or maintenance

Allowed:
- Detailed diagnostics
- Configuration changes
- Non-emergency command testing

Entry control:
- Protected entry (long press or pin) to prevent accidental activation in-cabin.

## 3. Information Hierarchy
Driver Mode should prioritize only what matters for SEM strategy.

Tier 1 (largest, always visible):
- Speed
- Instant efficiency (km/kWh)
- Average efficiency (session)
- Energy used
- Session timer
- Lap progress (for example 2/10)
- Lap crossing status
- Fault severity
- Critical warnings (thermal, powertrain, comms) with plain-language guidance

Tier 2 (compact, always visible):
- USB link status
- MQTT/cloud status
- Upload backlog status (unsent batches and oldest age)
- GPS lock
- Logging state
- Data freshness/stale indicator
- Auxiliary status strip: left signal, right signal, headlights, wipers, horn, hazards, brake light

Tier 3 (service mode only):
- Raw CAN payload table
- Per-cell voltages
- Fault code lists
- Device/service internals

## 4. Screen Architecture
Use a predictable shell with no accidental navigation during runs.

### Driver UI Change Boundary
1. Keep existing Driver Mode layout structure, spatial grouping, and visual hierarchy.
2. Apply only additive updates for new indicators and alerts in existing regions.
3. Avoid broad visual redesigns to typography, color system, or card geometry unless explicitly approved.

### Top Status Rail (persistent)
Shows:
- Session state (IDLE, ARMED, LOGGING, ENDED)
- USB status
- MQTT status
- upload backlog indicator
- Data freshness indicator
- UTC or local time
- Auxiliary indicator strip for body/aux states

Rules:
- Color must always match semantic state.
- Logging indicator must be impossible to miss.
- Auxiliary indicators are always visible in Driver Mode, even when actuation is locked.

### Main Race Panel
Center block:
- Speed value
- Threshold guidance (for example burn/coast windows)
- Lap crossing state

Left/right blocks:
- Instant and average efficiency
- Energy used and estimated remaining
- Session timer and lap/distance

Fault block:
- Dedicated area with clear severity and plain-language text.

Driver guidance block:
- Show one current coaching prompt at a time (for example COAST NOW, HOLD SPEED, BURN WINDOW).

### Service Panel (Service Mode)
Contains:
- Raw frames and decode stats
- BMS details
- Advanced metrics and queue depths

### Config Panel (Service Mode)
Contains:
- Thresholds
- Graph metric choice
- Endpoint and connectivity settings
- Simulation controls
- Session rules: target lap count, crossing filters, and crossing deadzone duration

## 4.1 Driver UX Flow
This is the required in-cabin UX flow during competition operation.

1. Boot to Driver Mode:
- session_state starts at IDLE.
- Driver sees run-critical metrics immediately, with stale markers if no data yet.

2. Arm Session:
- Driver confirms run name, destination, and lap target.
- session_state transitions to ARMED.

3. Start Preconditions:
- Vehicle must be at standstill (speed <= stop threshold).
- Standstill must be stable for minimum hold window.
- Start button shows READY only when preconditions are valid.

4. Start Run:
- Driver confirms start.
- session_state transitions to LOGGING.
- Service/config editing is locked.
- Any navigation that can hide critical telemetry is disabled.

5. Active Lap Cycle (repeats until target laps completed):
- Main panel stays visible and stable.
- Auxiliary indicators always remain visible.
- GPS source transitions are shown (external vs phone fallback).
- Link degradation and replay backlog state are shown in the status rail.
- Geofenced lap indicator detects lap boundary and confidence.
- Crossing filters and deadzone windows are applied.
- Lap count increments only after a valid filtered crossing.
- UI shows lap progress and deadzone/debounce state when active.

6. End Session:
- After target lap count is reached, lap_phase transitions to SESSION_COMPLETE while session_state remains LOGGING until driver confirms stop.
- Driver confirms stop/end.
- session_state transitions to ENDED.
- Session summary becomes available.

7. Service Access:
- Service Mode can be entered only after logging is inactive.
- Driver can return to Driver Mode in one tap.

## 4.2 Driver Action Checklist (Session)
1. Confirm ARMED state and lap target.
2. Verify START is enabled only at standstill.
3. Start run.
4. Complete lap driving segment.
5. At lap boundary, wait for crossing validation and deadzone clear.
6. Confirm lap count increment and continue running.
7. Monitor connectivity and backlog status in the top rail while running.
8. Repeat until lap target is reached.
9. End session after lap target is reached.

## 5. Navigation and Interaction Rules
1. Disable swipe-based page changes in Driver Mode.
2. Enter Service Mode only through explicit protected control.
3. Start session requires explicit confirmation.
4. Stop session requires explicit confirmation.
5. Dangerous commands require a second confirmation or hold-to-send behavior.
6. Any control that changes telemetry meaning is locked while logging.
7. Driver Mode must remain accessible with one tap from any service screen.
8. Auxiliary indicators remain visible in Driver Mode at all times.
9. End Session action is disabled until lap target is reached, except explicit emergency abort.

## 6. Control Safety for Bi-Directional Commands
All commands should be dictionary-driven and validated before send.

UI rules:
1. Commands are grouped by safety class: emergency, operational, maintenance.
2. In Driver Mode, only emergency class can be actuated.
3. Show command sent state: pending, acked, failed.
4. Show timeout countdown for pending commands.
5. Log every command action in service logs.
6. Non-emergency auxiliary controls can stay visible as status indicators in Driver Mode.

## 7. Visual Language
Optimize for sunlight readability and fast scanning.

1. Use high contrast combinations only.
2. Keep one color meaning per concept:
- Green: healthy/connected/within target
- Amber: warning/approaching limit
- Red: fault/out of bounds
- Cyan or blue: informational
3. Avoid decorative glow that reduces readability.
4. Use tabular numerals for all numeric values.
5. Keep label text concise and stable.

## 8. Data Freshness and Timing
UI cadence and ingest cadence must be decoupled.

1. Render at fixed UI rate (for example 30 to 60 Hz).
2. Preserve per-event timestamps in data layer.
3. For each displayed metric, show stale state if no update beyond threshold.
4. Use monotonic timestamps for ordering and graph interpolation.
5. In stale state, freeze last value and mark it visibly stale.
6. UI uses dual timestamp semantics:
- ts_wall_utc for absolute timeline displays.
- ts_session_ms for lap-relative overlays and run-relative metrics.

## 9. Alerting Behavior
Use clear severity bands.

Severity 0:
- No active faults

Severity 1:
- Advisory warning, no immediate action required

Severity 2:
- Action required soon (for example thermal approaching limit)

Severity 3:
- Critical, immediate attention required

Alert UX rules:
1. One active primary alert at a time in race view.
2. No alert animation that obscures key telemetry.
3. Alerts must include source and current value.
4. Alerts must include a clear driver action hint when applicable.
5. Lap crossing and deadzone alerts are prioritized during crossing windows.
6. Severity 2 and 3 alerts must trigger non-visual cues (audio or haptic) within the defined latency budget.
7. Alert cue delivery must use cooldown/dedup logic to avoid repetitive spam.

## 10. Remove or Move Out of Driver View
The following are unnecessary or risky in Driver Mode for SEM:

1. Theme toggle
2. Simulation toggle
3. API endpoint editing
4. Throttle map editing
5. Raw CAN reset actions
6. Non-essential command actuation (horn, wipers, etc.) unless required by your actual vehicle controls; keep their status indicators visible
7. Bouncy scrolling/page physics

These can remain in Service Mode.

## 11. Component and State Guidance
Recommended UI state split:

1. TelemetryRealtimeState
- Latest values for visible metrics
- Freshness timestamps
- Fault summary

2. SessionState
- Session id/name
- Logging state
- Session elapsed time

3. ConfigState
- Thresholds
- UI preferences
- Endpoint/configuration values

4. CommandState
- Pending commands
- Ack/fail statuses
- Retry counters

Widget guidance:
1. Use fine-grained selectors for metric widgets.
2. Keep expensive graph transforms out of build functions.
3. Keep painter repaints conditional on relevant data changes.

## 12. Text and Label Standards
1. Use concise labels with stable naming.
2. Avoid abbreviations that can be confused under pressure.
3. Keep units visible for all numeric values.
4. Use consistent capitalization and terminology.

Examples:
- Instant Efficiency (km/kWh)
- Average Efficiency (km/kWh)
- Energy Used (Wh)
- Session Time

## 13. Operational Acceptance Checklist
The UI is ready when all checks pass:

1. Driver can complete a full run without leaving Driver Mode.
2. No accidental navigation during vibration or touch noise.
3. All critical metrics remain readable in bright conditions.
4. Fault state is visible within one second of fault input.
5. Stale sensor data is clearly indicated.
6. Logging state cannot be mistaken.
7. Command send/ack/fail feedback is visible in Service Mode and emergency command status is visible in Driver Mode.
8. Driver can see all run-critical values without page changes.
9. Auxiliary status indicators (wiper, horn, hazards, signals, headlights) remain visible and accurate in Driver Mode.
10. Session state transitions follow IDLE -> ARMED -> LOGGING -> ENDED.
11. Lap indicator updates from geofence logic and shows confidence/source.
12. Session start is blocked until standstill precondition is satisfied.
13. Each lap increments only on valid filtered crossings after deadzone/debounce checks.
14. End Session is blocked until target laps are complete, except emergency abort.
15. Connectivity and upload backlog state are visible in Driver Mode while logging.
16. Severity 2 and 3 alerts are perceivable via non-visual channel in cabin conditions.

## 14. Implementation Priority for UI Work
1. Build Driver Mode single-screen layout and lock behavior first.
2. Add data freshness indicators and fault prioritization.
3. Move advanced controls and diagnostics to Service Mode.
4. Add command status widgets for dictionary-based serial TX.
5. Tune readability and spacing for actual test hardware.

This order reduces risk and aligns with competition use first.