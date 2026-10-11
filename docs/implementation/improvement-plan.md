# ECT Dashboard Improvement Plan

Implementation brief, 11 Oct 2026. Based on a read-through of `lugilugi/ect-dashboard` (rc.4). Record rates and timing errors below are estimates from the code, link settings and DBC cycle times. Size everything for the worst case (about 400 records/s while driving, 500 peak); no separate measurement step is needed.

---

## 0. How to execute this plan

### Before you start

- Read `AGENTS.md`, `docs/contracts/telemetry-v2.md` and `BACKEND_GUIDE.md`. They define the contract, checks and release rules this plan must keep.
- Toolchain: Flutter 3.41.5 (as pinned in CI), Python 3.12, Docker (for `tools/qualify_backend.py`).
- Work on a branch (for example `improvement/rc5`). Pushing, tagging and releases need the owner's explicit OK (`AGENTS.md`).
- Gate for every wave: `flutter pub get`, `flutter analyze --no-pub`, `flutter test --no-pub`, the Python unit tests, and `tools/qualify_backend.py` for **both** layouts when backend or contract files change.
- Settle the [open decisions](#open-decisions) first. Waves that depend on them are marked.

### Orchestration rules

1. **One orchestrator** (Claude Opus 5.5 or a senior engineer) owns the branch, splits work into waves, briefs subagents, reviews every diff and runs the gate. Subagents never merge their own work.
2. **One owner per file per wave.** Two agents never edit the same file at the same time. `dashboard_state.dart`, `config_view.dart` and `telemetry_runtime_coordinator.dart` are shared hot spots, so the waves below serialise them.
3. **Model by kind of work:**
   - **Claude Opus 5.5** for data-path and structural work: journal, recorder, MQTT sender, timing/clock code, state-store split, link state machine, SQL ingest. Mistakes here cause silent data loss or wrong timestamps.
   - **Claude Sonnet 5.5** subagents for mechanical work: feature removal, config edits, small refactors, test scaffolding, docs and changelog.
4. **Every subagent brief contains** the exact files it owns, the plan items it implements (by number), the acceptance tests, and "do not change the v2 telemetry contract, DBC or SQL columns unless the item says so".
5. **Independent review** for Waves 2, 3 and 6: a fresh Opus 5.5 agent that did not write the code reviews the diff against this plan and the contract before the gate.
6. Write the new tests for a wave **before** its refactor where possible (offline backlog, full budget, timing tests), so the refactor has a target.

### Waves

| Wave | Content (plan items) | Executor | Files owned | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Phase 0 (remove throttle mapping and driver alerts) + Housekeeping | One Sonnet 5.5 subagent (both removals touch the same files) | `config_view.dart`, `dashboard_state.dart`, `app_preferences_service.dart`, `telemetry_runtime_coordinator.dart`, `painters.dart`, alert files, `MainActivity.kt`, `AlertCuePlayer.kt`, `AndroidManifest.xml`, affected tests, `README.md`, `CHANGELOG.md` | Decision 1 and 2 |
| 2 | Phase 1 delivery path with design changes D2, D3, D4 (items 1.1, 1.2, 1.3) + journal upgrade fix 3.4 | One Opus 5.5 agent, sequential; Sonnet subagent may write test scaffolding | `telemetry_journal.dart`, `journal_record.dart`, `telemetry_recorder.dart`, `mqtt_service.dart`, `mqtt_transport.dart`, `spool_health_store.dart`, coordinator wiring only | Wave 1 |
| 3 | Timestamp accuracy fixes 2, 3 (app side), 4, 1 (phone side: prefix parser + `EspClockMapper`), 5 (phone GPS quality); timing tests; simulator emits ESP32 prefix | One Opus 5.5 agent | new `lib/core/time/`, `session_orchestrator.dart` (`SessionControlStore`), `usb_service.dart`, `can_ingest_repository.dart`, `can_bindings.dart`, `lap_boundary_service.dart`, lap code in `dashboard_state.dart`, `android_fused_location_service.dart`, `telemetry_recorder.dart` (time fields only) | Wave 2 (recorder API) |
| 3F | Timestamp fix 1 (firmware side) and fix 5 (GPS time-of-fix in DBC) | Firmware owner, with Opus 5.5 assisting; regenerate decoder with `tools/generate_can_dart.py` | ESP32 firmware repo, `dbc/network.dbc`, generated decoder, `docs/implementation/ble-link.md` | Wave 3 parser merged (it is backward compatible) |
| 4 | Phase 2 with D1 (state-store split, 2.1); then 2.2 CSV writer and 2.3 small wins | Opus 5.5 for D1; Sonnet 5.5 subagents for 2.2 and 2.3 after D1 lands | D1: `dashboard_state.dart`, `app_providers.dart`, UI files, coordinator. 2.2: `readable_local_copy_writer_io.dart`. 2.3: `can_bindings.dart` lookup, `driver_track_map.dart`, coordinator fallback loop | Wave 3 |
| 5 | Phase 3 with D5 (link supervisor: 3.1, 3.2, 3.6) and D6 (composition root: 3.3); 3.5 CSV logger manual ack | Opus 5.5 for D5 and D6; Sonnet 5.5 for 3.5 | `usb_service.dart`, `ingest_transport.dart`, `ble_nus_transport.dart`, `usb_serial_transport.dart`, coordinator, `main.dart`; `ops/backend/csv_streamer.py` | Wave 4 |
| 6 | Phase 4 backend with D7 (staging + merge job), timestamp fixes 6 and 7, Mosquitto, Grafana queries | Opus 5.5 for SQL/D7 and timestamp SQL; Sonnet 5.5 for `mosquitto.conf`, Grafana query edits, docs | `db/schema.sql`, `ops/backend/*`, `ops/local-stack/*`, `ops/grafana/*`, `BACKEND_GUIDE.md`, cutover doc | Decision 3; can run in parallel with Waves 4 to 5 (no shared files) |
| 7 | D8 and D9 if approved | Opus 5.5 | contract, ADR, recorder, server | Decisions 4 and 5 |

### Definition of done (per wave)

- The gate passes on the branch.
- The plan items for the wave are ticked here, with any deviation noted next to the item.
- `CHANGELOG.md` has an entry under the next rc.
- For Waves 2, 3, 6: the independent review found no unresolved issues, and the wave's new tests are in CI.

### Open decisions

1. Do the Grafana server-side alert rules (low pack voltage, GPS fallback, motor faults, telemetry stall) go too, or only the in-app driver alerts? This plan assumes **only the in-app alerts**. **Decided 11 Oct 2026: keep Grafana rules.**
2. What does the ESP32 do with its throttle curve once the app stops sending one? It should fall back to a fixed default.
3. Is a clean server reset acceptable for Phase 4, or must existing season data be migrated? **Decided 11 Oct 2026: clean reset.**
4. D8: agree per-signal deadband or maximum rates (changes data fidelity and the v2 contract).
5. D9: SQL receipts back to the phone (needs a new ADR).

---

## Summary

The plan runs in five phases. Phase 1 ends the upload backlog and the storage-limit recording stall, and is the biggest reliability win. Accurate timestamps are the top data-correctness requirement; they have their own section, and their app-side fixes ship with Phase 1. It starts by deleting two features, throttle mapping and driver alerts, so later work touches less code.

1. **Phase 0, remove features:** delete the throttle-map Config page and its ESP32 command. Delete the driver alert system (audio, haptics, thresholds, Config page).
2. **Phase 1, delivery path:** make the MQTT sender faster than capture. Stop the recorder retrying a rejected batch forever. Make journal saves cost the same regardless of backlog size.
3. **Phase 2, phone efficiency:** stop redrawing the UI on every CAN frame and write local CSV in bulk. Pick up the small ingest and map wins.
4. **Phase 3, edge cases:** fix the BLE connect race and add a silent-link watchdog. Make storage reset safe on error, future journal upgrades safe, and the server CSV logger lossless.
5. **Phase 4, backend:** fix Mosquitto queue limits and save interval, the compression window, the per-row insert trigger, and slow Grafana queries.

Phases 0 and 1 ship together as the next phone build (rc.5). Phases 2 and 3 can follow in the same or the next build. Phase 4 is server-only and can ship separately, but needs the matching backend qualification run.

---

## Design changes instead of patches

Seven structural changes would remove most Phase 1–4 fixes rather than add guards around them. Each replaces a pattern that keeps producing edge cases. Where one is adopted, the plan items it lists become its acceptance tests instead of separate patches.

| # | Pattern today | Change to | Absorbs |
| --- | --- | --- | --- |
| D1 | One 2,000-line `DashboardState` that calls `notifyListeners()` 79 times and carries 17 nullable `on…` callback hooks the coordinator fills in | Split into separate stores with their own providers: live telemetry (a value snapshot published at 30 Hz), session, config, link status, storage health. Services are passed in as interfaces instead of being attached as callbacks | 2.1 entirely; preference-signature rebuilds; most of 3.3 |
| D2 | Three timers polling each other: recorder commit every 50 ms, CSV export after every commit, MQTT sender every 1 s | One journal writer loop fed by a bounded queue, committing by size or time (group commit). After each commit it announces "committed up to id N"; the sender and CSV exporter wake on that instead of polling | 1.3 commit cadence, 2.2 export timing, the 1 s wait in 1.1 |
| D3 | Errors thrown after a successful commit, plus 14 silent `catch (_)` blocks | Typed results (`Stored`, `QuotaRejected`, `Conflict`, `IoError`), each with one defined policy in the writer: drop and count, dead-letter, or retry with backoff | 1.2 entirely; makes failures visible |
| D4 | Counters re-queried from SQLite after every write | The writer owns pending count, bytes and oldest id in memory and updates them on insert, ack and drop | Rest of 1.3 |
| D5 | Link lifecycle spread over 8 flags (`_open`, `_connecting`, `_started`, …) and `identical(transport, _transport)` checks | One link supervisor with an explicit state machine (Idle → Connecting → Open → Closing). Each attempt returns a cancellable `LinkSession` (byte stream + done future); backoff and RX-silence watchdog live in the supervisor | 3.1, 3.2, 3.6 |
| D6 | Storage reset rewires services one by one ("USB bindings keep their recorder reference") | A composition root that builds the whole runtime graph. Reset disposes it and builds a new one in `try/finally` | 3.3 |
| D7 | Row-by-row `INSTEAD OF` triggers with an `EXCEPTION` block on every insert | Telegraf writes to a plain staging table. A TimescaleDB job runs every 1–2 s and does one validated set-based `INSERT … SELECT … ON CONFLICT DO NOTHING`. Bad rows go to `ingest_rejections` via the same query. The job also upserts a `latest_signals` table | 4.2 trigger rewrite, alert-rule load in 4.3 |

### Two changes that need a decision first

**D8: Cut data volume at the source.** Today an observation is skipped only if its value is exactly unchanged, so noisy analog signals (motor current at 50 Hz) record every frame. The once-a-second snapshots add about 35 records/s on top. A per-signal deadband or maximum rate taken from DBC resolution, and dropping snapshots from transport, would make 1.1 and 4.1 far less urgent. The server already derives freshness from `observed_at` + `freshness_ms`. This changes data fidelity and the v2 contract, so the team should agree on per-signal rates.

**D9: SQL receipts instead of a deep broker queue.** The server could publish, per session, the highest sequence committed to SQL on a retained topic. The phone would then mark records SQL-confirmed and only prune confirmed ones. That replaces broker queue sizing (4.1) and manual reconciliation with an automatic guarantee. ADR 0001 explicitly left this to a separate protocol, so it needs a new ADR.

### Suggested order

D3 and D4 are small and go straight into Phase 1. D2 is Phase 1's main refactor. D1, D5 and D6 replace Phases 2–3. D7 replaces most of Phase 4, ideally at the same clean cutover. D8 and D9 wait on the decisions above.

---

## Timestamp accuracy (top priority)

Today no timestamp records when a CAN frame actually happened. Every CAN value is stamped when the phone's Dart code gets to it, using a wall clock that can jump. Graphs, lap times and energy per lap then mix that clock with a second, monotonic one. The contract already separates `observed_at_utc`, `ts_wall_utc` and `ts_session_ms`, which is the right shape; the problem is what goes into them. Error sizes are estimates, not measurements.

| # | Error source | Where | Typical size | Effect |
| --- | --- | --- | --- | --- |
| T1 | CAN time = phone arrival time. The candump line carries no ESP32 timestamp, so ESP32 queueing, BLE batching (flush every 20 ms, 7.5–15 ms interval), USB buffering and Dart event-loop delay all add up | `ingest_transport` → `usb_service._processBytes` → `can_ingest_repository.ingestLine` | 10–60 ms, worse when the UI is busy | Frames sent 20 ms apart arrive with the same time; rates such as power, acceleration and dI/dt are distorted |
| T2 | Two clocks: `ts_wall_utc`/`observed_at_utc` come from `DateTime.now()` (can step on network or NTP correction); `ts_session_ms` from a `Stopwatch` | `telemetry_recorder.dart`, `SessionControlStore` | 0 to several seconds when the clock steps | SQL plots and lap ends use `time`; lap durations and energy ordering use `ts_session_ms`. A clock step makes them disagree silently |
| T3 | The phone wall clock is never checked against true UTC. `VEHICLE_TIME` (GPS-synced RTC) is decoded but not wired | `can_bindings.dart` (`vehicleTime` case) | Seconds without network time at the track | Server freshness (`is_fresh`) compares phone time with server time; false stall or stale alerts; CSVs from different sources do not line up |
| T4 | An observation's `ts_session_ms` is the time it was processed, not the observation time | `TelemetryRecorder._event` (`state.sessionElapsedMs`) | Same as T1, plus queue delay | `ts_session_ms` and `observed_at` of the same row disagree |
| T5 | Lap crossing times: distance mode uses `DateTime.now()` at processing; geofence mode uses the GPS sample time, without interpolating between fixes. `Lap_Completed`'s `ts_session_ms` is when the recorder saw the notification | `dashboard_state.dart:895–900, 1978–1983`; `_captureMetadata` | Up to 200 ms per boundary at 5 Hz GPS | Lap times and per-lap energy/distance totals shift between laps |
| T6 | External GPS position time = arrival of `GPS_POSITION`, not when the receiver computed the fix | `can_bindings.dart` gpsPosition | 50–150 ms receiver latency, plus T1 | Track position lags the CAN signals plotted beside it |
| T7 | Phone GPS falls back to `DateTime.now()` when the fix has no timestamp, without flagging it | `android_fused_location_service.dart:49–51` | Unbounded | A stale fix can look current |
| T8 | Snapshot rows (copies of the last value, stamped at the 1 s tick) are included in `telemetry_seconds` averages, which are also unweighted by time | `schema.sql` `telemetry_seconds`, `lap_analytics` | Bias toward slow signals and toward sampler ticks | Average speed and power per second and per lap are skewed |

### Fixes

1. **Stamp CAN frames on the ESP32 (fixes T1, T4).** Decided 11 Oct 2026: adopt it. Prefix each line with the ESP32's microsecond counter at CAN receive, for example `(t_us) can0 ID#DATA`. The app converts ESP32 time to UTC with a fitted offset: take the minimum (arrival − ESP32 time) over a sliding window, which filters out queueing delay, and track drift. Keep phone arrival time as a fallback, and stamp it at `onBytes`, not after line parsing or the isolate hop. Needs a firmware change and hardware evidence, per `AGENTS.md`.
2. **One time base per session (fixes T2).** At session start, record an anchor pair (UTC, monotonic). Derive every timestamp as anchor UTC + elapsed monotonic time, so `ts_wall_utc`, `observed_at_utc` and `ts_session_ms` always agree. A wall-clock step then cannot move data. Log a `Clock_Step_Ms` diagnostic when the system clock disagrees with the anchor by more than 50 ms.
3. **Discipline the anchor to GPS UTC (fixes T3).** Wire `VEHICLE_TIME` and phone GNSS time. Estimate the phone-to-UTC offset, record it as a `Clock_Offset_Ms` metric every 10 s, and only re-anchor at session start. Mark each session's clock quality (`gps`, `network`, `unsynced`) in its metadata.
4. **Lap boundaries from source times (fixes T5).** Pass the triggering frame's time into the distance divider. In geofence mode, interpolate the crossing time linearly between the two fixes on either side of the line. Give `Lap_Completed` the crossing's own `ts_session_ms`.
5. **GPS fix time (fixes T6, T7).** Add the receiver's time of fix (GPS time-of-week, ms) to the GPS frames in the DBC, or at least the ESP32 stamp from fix 1. Set phone GPS quality to `invalid` instead of substituting `now`.
6. **Analytics on observations only (fixes T8).** Exclude `sample_kind='snapshot'` from `telemetry_seconds` and lap stats, and use time-weighted averages: `LEAD()` intervals, or `time_weight()`, which needs the timescaledb-ha image with the toolkit. Check the Grafana panels plot `observed_at`, not the snapshot tick time.
7. **Server freshness (fixes the alert side of T3).** Base `is_fresh` on clock-corrected time and show the session's clock quality on dashboards.

### What ESP32 stamping changes on the phone

The telemetry contract, SQL schema and record size stay the same. Only what goes into the existing time fields improves. The link carries about 14 more bytes per line, roughly 10 KB/s in total at 250 frames/s, well within USB and BLE.

| Area | Change |
| --- | --- |
| Line format | ESP32 sends `(t_us) can0 ID#DATA`, where `t_us` is `esp_timer_get_time()` (64-bit, µs since boot) read in the CAN receive handler. `CMD:` and ack lines are unchanged |
| Parsing | `usb_service._parseCandumpLine` accepts an optional `(t_us)` prefix. Lines without one still parse and fall back to arrival time, so old firmware keeps working. The isolate parser is retired (2.3) |
| Frame object | `CanFrameMessage` gains `espTimeUs` and the phone's monotonic arrival time, taken in `onBytes` |
| New clock mapper | `EspClockMapper` keeps the minimum of (arrival − ESP32 time) over a sliding window as the offset and tracks drift. It resets when `t_us` goes backwards (ESP32 reboot) or the link reconnects. It outputs times on the session time base (Fix 2) |
| Record times | For CAN observations, `observed_at_utc`, `ts_wall_utc` and `ts_session_ms` all come from the mapped ESP32 time, so the three always agree |
| Lap boundaries | The distance divider uses the triggering frame's mapped time (Fix 4) |
| Diagnostics | New metrics `Esp_Clock_Offset_Ms` and `Esp_Clock_Jitter_Ms` every 10 s, plus a count of lines that fell back to arrival time. The session metadata notes whether ESP32 time was used |
| Simulator and tests | The simulator emits the prefix with known times, so the timing tests in this section run in CI without hardware |
| Unchanged | Sequence numbers, change suppression, freshness rules, journal, MQTT, CSV columns, server SQL |

### Timing tests

- [ ] **End-to-end:** feed frames with known ESP32 times through the simulator; check that SQL `observed_at` matches within 5 ms after offset convergence.
- [ ] **Clock step:** move the phone wall clock ±30 s mid-session; check that no row's time moves and that `Clock_Step_Ms` is logged.
- [ ] **Lap timing:** replay a GPS track with a known crossing time; interpolated lap time within 20 ms.
- [ ] **Burst arrival:** deliver 10 frames in one BLE notification; check that their times keep their 20 ms spacing.

Fixes 2, 4, 6 and 7 are app or SQL only and fit Phase 1. Fixes 1, 3 and 5 also need ESP32 and DBC work (Wave 3F).

---

## Phase 0: Remove throttle mapping and alerts

Both features are app-only. Removing them changes no telemetry fields, SQL columns or DBC signals. `Throttle_Percent` stays, because it is a CAN reading, not part of the mapping feature.

### Throttle mapping

Today the Config → Throttle page edits a 5-point curve and sends `CMD:THROTTLE_MAP:…` to the ESP32 over USB/BLE. It is not saved in preferences.

| Area | File | Change |
| --- | --- | --- |
| Config page | `lib/ui/widgets/service/config_view.dart` | Delete `_buildThrottleSection` (about lines 2099–2381), `_buildThrottleStatusPill`, `_updateThrottleMapFromGraph`, the Throttle rail item and its `switch` case; drop `ConfigSection.throttle` |
| State | `lib/providers/dashboard_state.dart` | Delete `throttleMap`, `throttleMapDraft`, `selectedThrottleMapProfile` and `throttleMapPresets` from `ConfigStateStore`, plus the getters and `updateThrottleMap` … `_throttleMapEquals` (about lines 1227–1250, 1675–1757) |
| Painter | `lib/ui/widgets/common/painters.dart` | Delete `ThrottleMapPainter` (the whole file if nothing else uses it) |
| Tests | `test/` | Remove or adjust any throttle-map assertions |

- [ ] *(Pending firmware owner; noted in CHANGELOG rc.5.)* Confirm the ESP32 firmware's behaviour once it stops receiving `THROTTLE_MAP`. It should use a fixed default, not the last map it was sent. If it saves the map, add a one-off reset or document it.
- [x] Leave the shared command path (`CanTxService`, deadman, `sendUsbCommand`) untouched; other commands use it.

### Driver alerts

The alert system watches state and plays audio cues through a native channel, triggers haptics and records the last alert. It has a Config → Alerts page and 8 saved preferences.

| Area | File | Change |
| --- | --- | --- |
| Service | `lib/services/orchestration/driver_alert_service.dart` | Delete the file (the `DashboardState` listener, cue player and repeat timer go with it) |
| Models | `lib/models/alerts/driver_alert_models.dart` | Delete the file |
| Runtime | `lib/services/orchestration/telemetry_runtime_coordinator.dart` | Remove the import, the `_driverAlertService` field, `start()` and `stop()` |
| State | `lib/providers/dashboard_state.dart` | Delete `AlertStateStore`, the alert getters and setters, `recordAlertEmission`, `alertVariableValue`, `onRequestAlertTestTone`, the last-alert text getters |
| Preferences | `lib/services/persistence/app_preferences_service.dart` | Remove the 8 `_kAlert*` keys from restore, save and `buildStateSignature`; call `prefs.remove(...)` once on startup to clear the old values |
| Config page | `config_view.dart` | Delete `_buildAlertsSection` (about lines 2593–2707), `_buildThresholdField` if unused, the severity colour helper, the Alerts rail item; drop `ConfigSection.alerts` |
| Android | `android/app/src/main/kotlin/com/example/telemetry_dashboard/MainActivity.kt`, `AlertCuePlayer.kt` | Remove the `ect_dashboard/alert_cue` channel and delete `AlertCuePlayer.kt`; drop the `VIBRATE` permission if nothing else uses it. (The Kotlin files were not reviewed; check the channel registration by hand) |
| Tests | `test/driver_alert_service_test.dart`, `test/phase7_hardening_alerts_test.dart`, `test/driver_panel_test.dart` | Delete the alert-only tests; trim shared tests |
| Docs | `README.md`, `CHANGELOG.md` | Note the removal under rc.5 |

### Exit check

*Wave 1 done 11 Oct 2026: analyze clean, 89 tests pass (13 alert-only tests deleted), five Config sections; remaining `alert` hits are `AlertDialog`, a foreground-notification flag, a CAN enum value and the retired-preference key list.*

`flutter analyze` is clean and `flutter test` passes. A grep for `alert` (excluding `AlertDialog`) and for `throttleMap` returns nothing in `lib/` or `android/`. Config shows five sections.

---

## Phase 1: Delivery path

The phone records roughly 350–400 records/s while driving, but uploads at most 256/s. The backlog therefore grows by about 100–150 records/s and fills the 256 MiB limit in roughly an hour. These three fixes are linked and should land together (Wave 2).

### 1.1 Make upload faster than capture

`lib/services/transport/mqtt_service.dart` sends one 32-record batch, waits for PUBACK, stops after 8 batches and runs once a second (lines 36, 99–102).

- [x] Keep up to 8 batches in flight at once (Mosquitto allows 20 per client). Read about 256 pending records per pass.
- [x] Keep pumping while a backlog exists, and trigger a send right after each journal commit instead of waiting for the 1 s tick.
- [x] Build each envelope by joining the stored `payload_json` strings and summing `payload_bytes`. Today `encode()` re-encodes and re-decodes the whole batch for every record added (lines 106–115).
- [x] Mark a whole round as acknowledged in one transaction (`UPDATE … WHERE id IN (…)`), with the attempt count folded into the same statement.
- [x] Add exponential reconnect backoff (1 s up to 15 s), resetting on success.
- **Target:** at least 1,500 records/s on a LAN qualification run, and a 10-minute offline backlog clears in under 3 minutes.

### 1.2 Stop the storage-limit recording stall

When the pending limit is hit, `appendRecords` writes loss rows and then throws (`telemetry_journal.dart:173–212`). `_commit` only clears its buffer on success (`telemetry_recorder.dart:197–198`). It therefore retries the same batch every 50 ms and adds up to 240 rows to the never-pruned `recording_losses` table each time. All new capture is dropped while this happens.

- [x] Return a result from `appendRecords` (stored / rejected-for-quota) instead of throwing after commit. On rejection, clear those records from the buffer and count the loss once.
- [x] Store one `recording_losses` row per rejected batch with a count, not one per record. Prune it alongside the journal.
- [x] Move a record that fails permanently (a conflicting identity) into a `journal_failed` table and continue. Show the count in Storage health.
- [x] Add a test that fills the budget, drains it, and checks that recording resumes and losses are counted once.

### 1.3 Keep journal saves cheap as the backlog grows

Each 50 ms save runs one lookup per record and adds up all pending bytes. `refreshHealth()` then runs a second full count/size/oldest query (lines 152–168, 335–352).

- [x] Keep pending bytes and count in memory, loaded once at open. Adjust them inside insert, ack and drop. Optionally mirror them in a one-row `journal_stats` table updated in the same transaction.
- [x] Use `INSERT OR IGNORE` and only read the existing row when the insert was skipped, to compare content.
- [x] Read "oldest pending" from the lowest pending `id` (indexed) instead of `min(enqueued_at_utc)`.
- [x] Raise the commit interval from 50 ms to 200–250 ms, and only rewrite the checkpoint when its JSON changes. This cuts fsyncs roughly 4×. Keep `synchronous=FULL`.
- [x] Raise the capture buffer to cover a 1 s stall at peak rate (about 600 records).
- **Target:** save time stays flat (under 10 ms on a mid-range phone) with 500k pending records.

---

## Phase 2: Phone efficiency

The main cost is about 300 full-app notifications a second from CAN frames. Moving telemetry onto the existing 30 Hz frame tick removes most of it, and with alerts gone (Phase 0) there is one fewer listener to keep fed.

### 2.1 Stop redrawing on every CAN frame

`updatePedal`, `updatePackPower`, `updateAuxPower`, `updateEnergy`, `updateMotion` and `updateMotorFaults` each call `notifyListeners()`. Each call:

- redraws the status bar (`dashboard_screen.dart:436`);
- redraws the whole `ConfigView` when visible (`config_view.dart:82`);
- rebuilds the preference signature, `jsonEncode` included (coordinator `_handleStatePreferenceSync`);
- runs the recorder's metadata check.

Tasks (or do D1 instead):

- [ ] Add a `_telemetryDirty` flag. Telemetry setters set it and do not notify. The `uiFrame` timer only increments when the flag is set, then clears it.
- [ ] Keep `notifyListeners()` for session, configuration and connection changes only.
- [ ] Status bar: watch a `select` of the fields it shows, or rebuild on `uiFrame`. Move `_syncOfflineDebounce` out of `build`.
- [ ] `ConfigView`: replace the whole-state `ref.watch` with per-section `select`s. Live readouts listen to `uiFrame`.
- [ ] `SpoolHealthStore`: only notify when the error text or count actually changes. Round backlog age to whole seconds so it notifies at most once a second.
- **Target:** with the car idle on the driver page, no widget rebuilds between frames.

### 2.2 Write local CSV in bulk

`flushExports()` runs after every save, and `_appendCsvRow` makes about 5 file-system calls per row, then fsyncs each file (`readable_local_copy_writer_io.dart:120–183`).

- [ ] Export on its own 2 s timer, plus on session stop and app close, instead of after every commit.
- [ ] Keep each open file's size in memory; check existence once when the file opens.
- [ ] Group a page of rows by file and write each group with one `writeString`, then flush once per page.

### 2.3 Small wins

- [ ] Parse candump lines directly with `_parseCandumpLine` and retire the isolate in `can_ingest_repository.dart`. Each line currently pays two message hops for a regex that takes microseconds.
- [ ] Replace `canTelemetryBindingFor`'s linear search with a map keyed by `(canId, signal)` built once.
- [ ] `_processBytes`: scan the buffer by index and cut the remainder once per chunk, instead of a `substring` per line.
- [ ] Driver track map: keep a cached `List<LatLng>` and `Polyline`, rebuilt only when a GPS point is added (add a track version counter). Return the track list without copying it each frame.
- [ ] Merge the 8 near-identical `_recorder.record` calls in `_publishPhoneFallbackTelemetry` into a loop.

---

## Phase 3: Reliability edge cases

Each item below can leave the link, upload or a future upgrade stuck until the app restarts. Each is small, and each gets its own test. D5 and D6 replace 3.1, 3.2, 3.3 and 3.6 if adopted.

| # | Problem | Where | Fix |
| --- | --- | --- | --- |
| 3.1 | If the link is closed during a BLE connect, the attempt can still mark itself open. The reconnect timer then never fires | `ble_nus_transport.dart` `_openLink` / `_teardown` (lines 196–375) | Add a connect-attempt counter, increase it in `_teardown`, and check it after every `await` in `_openLink`; tear down if it changed |
| 3.2 | A USB or BLE link that is "open" but silent (ESP32 hung, notifications stopped) is never reconnected | `usb_service.dart` | Track last-RX time; if over 5 s (configurable) with no bytes while open, close and reconnect, and log it |
| 3.3 | Clearing local storage has no `try/finally`; one failed step leaves ingest and upload stopped | `telemetry_runtime_coordinator.dart` `_resetLocalStorage` | Wrap in `try/finally` so the recorder, MQTT and link always restart; show the error |
| 3.4 | `onUpgrade` re-runs `_create()` without `IF NOT EXISTS`, so the next version bump crashes on phones that already have `journal` | `telemetry_journal.dart:70–81` | Use `IF NOT EXISTS` and write explicit per-version migrations; add an upgrade test from v4 |
| 3.5 | The server CSV logger confirms messages before its 1 s disk sync, so a crash can lose up to 1 s | `ops/backend/csv_streamer.py:105, 116` | Use paho 2.x `manual_ack=True` and confirm message ids after `flush_all()` |
| 3.6 | USB `port.open()` failure leaves the port object unclosed, and "Found USB device" is logged every 3 s | `usb_serial_transport.dart:144–156` | Close on failure; throttle that log line |

---

## Phase 4: Backend

The biggest backend risk is the broker dropping data after about 15–20 minutes of Telegraf or database downtime. The rest are load fixes that matter more as the season's data grows. Apply changes to both layouts (compose and single container), since they share inputs.

### 4.1 Mosquitto (`ops/backend/mosquitto.conf`)

- [ ] Replace `max_queued_messages 10000` with a byte budget: `max_queued_bytes` of about 1.5 GB per client (2 hours at 400 records/s and ~450 bytes per event). Keep a message cap as a backstop.
- [ ] Change `autosave_interval 1` to 15–30 s. Today the whole save file is rewritten every second. The trade-off: a broker crash can lose up to that window, which the phone's 7-day history and reconcile tool cover.
- [ ] Add a Grafana or healthcheck alarm on queue depth for the Telegraf client, so drops are noticed rather than silent.

### 4.2 TimescaleDB (`db/schema.sql`)

- [ ] Move `add_compression_policy` from 2 hours to 2 days, so late phone uploads land in uncompressed chunks.
- [ ] Rewrite `ingest_metric()` and `ingest_session()` without the `EXCEPTION` block (or adopt D7). Check each cast with `pg_input_is_valid()` (PG16) and each range by hand, then insert or log a rejection. This removes one savepoint per row (1,000 per Telegraf batch).
- [ ] Make `telemetry_seconds` a continuous aggregate with real-time aggregation, and point `lap_analytics` at it (combine with timestamp fix 6).
- [ ] Add a partial index for lap crossings: `ON telemetry_raw(session_uid, lap_number, time) WHERE signal_name='Lap_Completed'`.
- [ ] The schema is fresh-only, so these need either a clean cutover (`docs/implementation/cutover.md`) or a first migration script (Decision 3).

### 4.3 Grafana queries

- [ ] Add a `latest_session` view that reads only the `sessions` table (`ORDER BY started_at DESC LIMIT 1`). Today each alert rule computes `session_catalog`, a `GROUP BY` over all of `telemetry_raw`, every minute.
- [ ] Compare `session_uid` as a UUID, not `session_uid::text`, so the `telemetry_lookup` index is used.
- [ ] Check the dashboard JSON queries (`ops/grafana/dashboards/*.json`, not reviewed) for the same two patterns.

The alert-rule query changes only apply if those rules stay (Decision 1).

---

## Housekeeping

- [x] *(Declined by owner; OneDrive sync disabled instead.)* Move the repo out of OneDrive (for example `C:\dev\ect-dashboard`). OneDrive syncing `.git`, `.dart_tool` and `build/` (70 MB kernel files) can corrupt the repo and keeps re-uploading build output.
- [x] *(Clean: not tracked, absent from all history.)* Run `git ls-files android/key.properties android/app/upload-keystore.jks` and confirm it prints nothing. Both files exist locally and are ignored, but check they were never committed.
- [x] Delete the stray `ops/backend/__pycache__` folder and make sure `.dockerignore` excludes it.
- [x] Update the `pubspec.yaml` description from "A new Flutter project."

---

## Testing and rollout

Each wave is done when the gate passes (see section 0). Phase 1 also needs the new tests below.

### New tests

- [ ] **Offline backlog:** run the simulator for 10 minutes with the broker down, then reconnect. Pass if the backlog clears faster than capture and no records are lost or duplicated in SQL after dedup.
- [ ] **Full budget:** set a small `maxPendingBytes`, fill it, drain it. Pass if recording resumes on its own and losses are counted once.
- [ ] **BLE race and silent link:** fake transports that close mid-connect and that stop sending data.
- [ ] **Journal upgrade:** open a v4 database with a v5 build.
- [ ] **Timing tests:** see the Timestamp accuracy section.

### Rollout

1. Ship Phases 0–3 and the app-side timestamp fixes as phone build rc.5; tag only after hardware qualification on a real phone and CAN bridge.
2. Ship Phase 4 with a clean backend cutover or a migration script, qualified on both layouts.
3. Ship ESP32 firmware with frame timestamps once the phone parser (backward compatible) is in a released build.
