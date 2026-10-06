# ECT telemetry dashboard

Flutter in-cabin dashboard with Driver/Service views, USB/CAN ingest, GPS,
session/lap control and two Docker backend layouts.

~~~mermaid
flowchart LR
  CAN[CAN / USB] --> R[Flutter recorder]
  GPS[GPS fixes] --> R
  R --> J[SQLite journal / checkpoint]
  J --> LC[Local CSV]
  J --> M[MQTT sender]
  M --> B[Mosquitto]
  B --> T[Telegraf]
  T --> S[Validated SQL ingest]
  S --> DB[TimescaleDB read models]
  DB --> G[Grafana]
  B --> C[Independent CSV logger]
  C --> H[Read-only CSV downloads]
~~~

Each version-2 record keeps its own identity, capture/observation time, lap and
source. Signals and metadata can arrive in any order. The live phone display,
USB and command/deadman control remain independent of SQL.

- [Backend setup/operations](BACKEND_GUIDE.md)
- [Architecture/contract](docs/architecture/telemetry-pipeline.md)
- [Clean cutover and hardware gate](docs/implementation/cutover.md)
- [Verification evidence](docs/implementation/verification.md)
- [CAN DBC](dbc/network.dbc) / [bindings](lib/models/telemetry/can_bindings.dart)

## Development

~~~sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
python -m unittest discover -s ops/backend -p 'test_*.py'
python -m unittest discover -s tools -p 'test_*.py'
~~~

Run with flutter run -d windows or a configured Android device. USB port/baud and
MQTT endpoint are editable in Service Connectivity. After DBC changes run
python tools/generate_can_dart.py and commit the generated decoder.

edge_spool.db now stores immutable metric/session records, delivery state,
watermarks, export cursor and a checkpoint. Pending JSON has a 256 MiB budget;
bounded capture reports recording loss instead of silently claiming durability.
There is no automatic RAM fallback. Version-2 local CSV rotates and follows
configured retention. ACKed history is kept seven days after CSV export.

Server CSV is at least once and can contain duplicates. Reconciliation compares
identities and immutable context/value fields. Broker PUBACK is handoff, not proof of SQL durability.

This requires a matching clean-reset phone/server pair. Real Android/CAN
qualification and APK build are pending; no release is declared. Release tags
trigger the existing signed-APK workflow after that separate gate is satisfied.
