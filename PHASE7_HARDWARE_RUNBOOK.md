# Phase 7 Hardware Endurance Runbook

This runbook closes the remaining hardware-only matrix items from Phase 7.

## Scope

The matrix covers:

1. 10-minute sustained replay while telemetry is active.
2. Repeated physical USB disconnect/reconnect cycles.
3. Screen-off foreground soak on target Android hardware.

## Test Environment

1. Device: target Android tablet/phone used in-cabin.
2. App build: latest main branch with analyzer and tests passing.
3. ESP32/CAN bridge connected over USB OTG.
4. MQTT broker reachable on expected network.
5. Service Mode available for diagnostics and readable mirror export.

## Preflight Checklist

- [ ] App launches and enters Driver mode with no crash.
- [ ] USB status can transition connected/disconnected.
- [ ] MQTT status can transition connected/disconnected.
- [ ] Local readable mirror shows files and preview lines.
- [ ] Export mirror action succeeds and returns an export path.
- [ ] Session start gate works from standstill.

## Matrix Overview

| ID | Scenario | Duration / Cycles | Primary Pass Criteria |
|---|---|---:|---|
| H1 | Sustained replay under active logging | 10 minutes | No UI lockup, no crash, backlog drains after reconnect |
| H2 | Physical USB reconnect stress | 20 cycles | Recovery after each reconnect, no invalid lap count burst |
| H3 | Screen-off foreground soak | 20 minutes | Telemetry runtime stays alive and session remains recoverable |

## H1: 10-Minute Sustained Replay

### Steps

1. Start app in Driver mode.
2. Arm and start a session.
3. Run telemetry input continuously for 10 minutes (real or deterministic simulator feed).
4. During the run, force one 2-5 minute MQTT outage.
5. Restore MQTT connectivity.
6. Continue until total elapsed logging time reaches 10 minutes.
7. Stop session normally.
8. Enter Service mode and export readable mirror snapshot.

### Observe and Record

1. Max unsent queue count shown in Driver top rail.
2. Oldest unsent age peak and recovery.
3. Any app freezes, frame hitching, or watchdog restarts.
4. Final queue state after reconnect (expected zero backlog).

### Pass Criteria

- [ ] No crash or ANR.
- [ ] Session remains active and can be stopped normally.
- [ ] Replay drains to zero backlog after reconnect.
- [ ] Exported mirror contains publish attempts and decoded event lines for outage window.

## H2: Physical USB Reconnect Stress (20 Cycles)

### Steps

1. Start app and begin a logging session.
2. Repeat 20 times:
   1. Disconnect USB cable from device.
   2. Wait 5-10 seconds.
   3. Reconnect USB cable.
   4. Wait for USB connected indicator and telemetry recovery.
3. Stop session after the 20th successful recovery.
4. Export readable mirror snapshot.

### Observe and Record

1. USB reconnect latency per cycle (seconds).
2. Count of failed recoveries.
3. Unexpected lap increments during reconnect periods.
4. Alert behavior: disconnected warnings should be deduplicated by cooldown.

### Pass Criteria

- [ ] At least 19/20 reconnect cycles recover without app restart.
- [ ] No runaway lap counter increments during reconnect churn.
- [ ] No duplicate alert storm during repeated disconnect events.
- [ ] Session remains controllable and ends cleanly.

## H3: Screen-Off Foreground Soak (20 Minutes)

### Steps

1. Start app and begin a logging session.
2. Turn the device screen off (or lock device).
3. Keep telemetry source active for 20 minutes.
4. Briefly wake screen every 5 minutes only to confirm app is alive.
5. At 20 minutes, unlock, verify session state, and stop session.
6. Export readable mirror snapshot.

### Observe and Record

1. Whether session stayed in ARMED/LOGGING as expected.
2. Whether USB/MQTT state resumes immediately on wake.
3. Whether backlog unexpectedly spikes due to background throttling.
4. Whether recovery resume count changed unexpectedly.

### Pass Criteria

- [ ] Foreground service keeps runtime alive through screen-off window.
- [ ] Session is still active and state-consistent on wake.
- [ ] Telemetry and replay behavior remain bounded.
- [ ] App exits session cleanly without forced restart.

## Evidence Capture

Capture and archive:

1. Exported readable mirror folder path.
2. Device model and Android version.
3. Build hash or branch + timestamp.
4. Any screenshots of error state.
5. Summary notes for each matrix row.

## Result Template

### H1 Result

- Outcome: PASS / FAIL
- Notes:

### H2 Result

- Outcome: PASS / FAIL
- Notes:

### H3 Result

- Outcome: PASS / FAIL
- Notes:

## Exit Decision

Phase 7 hardware matrix can be marked closed when all three scenarios pass on target hardware in at least one full run and no critical data-loss or control-path regression is observed.
