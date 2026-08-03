# AGENTS.md

Flutter in-cabin telemetry dashboard (`telemetry_dashboard`) for ECT Shell
Eco-marathon + a Docker backend (Mosquitto + Telegraf + TimescaleDB +
Grafana). Repo root is a Flutter app; backend lives under `ops/` and `db/`.

## Commands

- `flutter pub get` then `flutter analyze --no-pub` and `flutter test --no-pub` (CI does exactly this, on PR/push to `main`). Always run both after Dart changes.
- Run on the dev laptop: `flutter run -d windows`. USB serial is auto-detected; pin a port with `--dart-define=DESKTOP_SERIAL_PORT=COM5`.
- Release: pushing a tag (e.g. `v1.0.0`) triggers `.github/workflows/android_release.yml` — analyze+test, sign with keystore from secrets, attach APK to a GitHub Release. Same key every build ⇒ new versions install over the old APK (no uninstall). `--build-name` comes from the tag, `--build-number` from the run number.
- Backend (single container): `docker build -t ect-backend -f ops/backend/Dockerfile .` from the repo ROOT (whole repo is build context), then `docker run -d --name ect-backend -p 1883:1883 -p 5432:5432 -p 3000:3000 -e POSTGRES_PASSWORD=... -e GRAFANA_ADMIN_PASSWORD=... ect-backend`. Compose alternative: `cd ops/local-stack && docker compose up --build -d` (`down -v` wipes the DB).

## App architecture (what's easy to get wrong)

- Ingest: `lib/services/ingest/usb_service.dart`. Android uses `usb_serial` and picks Espressif native USB (VID 0x303A) or ESP32 WROOM bridge chips (CP210x 0x10C4, CH340 0x1A86, FTDI 0x0403), else the first device. Desktops use `flutter_libserialport`: explicit dart-define wins, otherwise `SerialPort.availablePorts` is auto-tried (ttyACM → ttyUSB → others). Port choice precedence: Config → Connectivity → USB PORT SELECT (persisted in prefs) > `--dart-define=DESKTOP_SERIAL_PORT=COM5` > auto-detect. ESP32-C3 USB Serial/JTAG ignores baud; classic UART bridges need firmware-matching baud (115200).
- MQTT endpoint (host + port) is editable in Config → Connectivity → MQTT ENDPOINT; host/port live on `DashboardState` (`mqttHost`/`mqttPort`, persisted) and `MqttService` rebuilds its transport + reconnects on change (`_reconnectWithNewEndpoint`).
- Input format is candump lines: `can0 <id>#<hexpayload>` (newline-delimited). `CanIngestRepository` parses in an isolate; `_dispatchPayload` in `usb_service.dart` decodes and publishes.
- **Adding a CAN signal**: edit `lib/models/telemetry/can_signal_registry.dart` (single source of truth, CamelCase + unit suffix, e.g. `Speed_Kmh`) AND add the value in the matching `_dispatchPayload` case. No backend/schema changes needed (EAV sink).
- `lib/services/orchestration/telemetry_runtime_coordinator.dart` constructs every service; `DashboardState` (`lib/providers/dashboard_state.dart`) is a big ChangeNotifier whose UI-observable stores (spool health, USB debug log) are attached via `attach*Store(...)` — copy that pattern for new service state.
- USB debug log: `UsbDebugLogStore` (bounded ring buffer, throttled by UsbService — RX stats every 5 s, connect failures deduped) → Config → Connectivity → "USB DEBUG LOG".
- MQTT: sparse JSON batch of changed values to `telemetry/eco_archers/events`; session upsert to `.../sessions`. `ts_wall_utc` is the metric timestamp, so outage replays keep original timing. Local spool replays after broker outages (see `local_spool_service.dart`, `mqtt_service.dart`).

## Backend gotchas (verified in BACKEND_GUIDE.md)

- `telemetry_raw` tag columns (`session_uid`, `lap_number`, `ts_session_ms`, `seq_*`) are **TEXT**, not uuid/int — Telegraf ≥1.31 `outputs.postgresql` COPYs tags as strings in binary format and fails with `08P01`/`22P03` otherwise. Cast in queries: `lap_number::int`.
- Grafana provisioning env vars use Go `os.ExpandEnv`: plain `${VAR}` only — `:-default` expands to an EMPTY string (silently broken datasource). Grafana ≥13 changed the default provisioning path; the Dockerfile sets `GF_PATHS_PROVISIONING=/etc/grafana/provisioning-ect`.
- Grafana timezone is machine-local: `GF_DASHBOARDS_DEFAULT_TIMEZONE=browser` (Dockerfile + compose) and `"timezone": "browser"` in the dashboard JSONs.
- Grafana SQL must constrain `time` (hypertable chunk pruning) and down-sample with `time_bucket('$__interval', ...)`; lap overlays normalize with `ts_session_ms` window functions.
- `vehicle_setup` (JSONB) is deliberately NOT ingested (Telegraf `json_v2` can't stringify nested objects — it zeroes the whole metric batch).
- `db/schema.sql` runs only on an empty Postgres data volume (`/docker-entrypoint-initdb.d`); wipe the volume to re-apply.
- Mosquitto ships anonymous/plaintext — dev only; harden per `ops/mosquitto/README.md` before any untrusted network.

## Tests

- `test/` is per-service unit/widget suites; 77 tests, no backend or hardware required. `flutter test` needs no special flags. New service logic should get a matching suite (see `test/can_tx_service_test.dart`, `test/mqtt_replay_outage_test.dart` for style).

## Environment quirks

- Repo lives under OneDrive and the path contains spaces — always quote paths.
- `csv_exports/` and `build/` are local artifacts; keep them out of commits.
