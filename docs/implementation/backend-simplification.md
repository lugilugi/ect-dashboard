# ECT backend simplification: clean-reset implementation plan

**Status:** stages 01–09 implemented; both layouts passed automated software qualification. The actual-device part of stage 08 and release/cutover remain open. Android APK and real phone/CAN qualification remain pending by user instruction. See [verification evidence](verification.md) and [cutover gate](cutover.md).

**Baseline:** [main at 5cdb2cc2cd860a164177c7b9c40443d07aeee169](https://github.com/lugilugi/ect-dashboard/commit/5cdb2cc2cd860a164177c7b9c40443d07aeee169), audited on 6 October 2026. Reconcile subsequent changes before implementation.

**Scope decision:** existing telemetry does not require migration or backward compatibility. Start with a clean schema and a coordinated matching phone/server release. The earlier preserving-migration and dual-reader proposal is superseded.

## Intended result

Flutter remains responsible for decoding CAN, choosing GPS sources, sessions/laps, commands, and immediate Driver/Service display. One recorder assigns capture context. One SQLite journal is the durable outbox. One sender publishes journal records. Telegraf adapts them into one narrow TimescaleDB telemetry schema, and shared SQL views supply Grafana calculations.

Retain local readable CSV and the independent server MQTT-to-CSV archive. Remove legacy wire readers, dual-version topics, historical-data unions, old queue conversion, and the separate publish_batches mechanism. Do not recreate the unused laps table or vehicle_setup field.

~~~mermaid
flowchart LR
  CAN[USB / CAN decode] --> UI[Immediate Driver / Service state]
  GPS[GPS source selection] --> UI
  CAN --> REC[Recorder + session context]
  GPS --> REC
  SESSION[Session / lap runtime] --> REC
  REC --> JOURNAL[SQLite journal + outbox]
  SESSION --> CP[Session control checkpoint]
  CP --- JOURNAL
  JOURNAL --> LOCALCSV[Recoverable local CSV export]
  JOURNAL --> SEND[One MQTT sender]
  SEND --> MQTT[Mosquitto]
  MQTT --> TG[Telegraf contract adapter]
  TG --> INGEST[Validated SQL ingest views]
  INGEST --> DB[Sessions + one telemetry hypertable]
  DB --> VIEWS[Shared analytical views]
  VIEWS --> GRAF[Grafana]
  MQTT --> CSV[Independent server CSV archive]
  CSV --> HTTP[CSV HTTP in both Docker layouts]
~~~

SQL centralizes server analytics. It does not synchronize sensors, control phone operation, or put database/network latency in the live UI path.

## Decisions for the implementation

### One flexible record contract

Build on the existing DecodedMetricEvent. Each metric carries its own session_uid, seq_in_session, lap context, signal_name, finite numeric value, optional unit, source, quality, timestamps, elapsed session milliseconds, and sample_kind. GPS latitude/longitude from one fix share source_sample_id.

Use an events-array payload with schema_version = 2. Repeated signal names remain separate records; there is no batch-wide timestamp/lap assignment or requirement for synchronized signals. Unknown metric names remain valid. Adding a signal does not require a database column.

Keep current metric aliases such as Voltage_780 where meaningful. A storage reset does not require unrelated DBC, firmware, command, or UI changes.

Use the existing events and sessions topic names with the new incompatible contract:

- telemetry/eco_archers/events
- telemetry/eco_archers/sessions

There is one active format and one reader per topic. The cutover stops old publishers and clears old application queues/subscriber sessions before new traffic starts. Wrong payload versions must be diagnosed.

### Truthful time, sampling, and ordering

Separate observation time, record time, and server receipt time. For an observation, ts_wall_utc is the original CAN receipt/GPS timestamp. For a periodic snapshot it is the sampling tick, while observed_at_utc retains the underlying observation time. Freshness uses observed_at_utc. Replay never replaces these times.

Maintain changed-value suppression and the existing one-second sampling intent. Refresh source age on every observation, even when its value is unchanged. Sample only fresh state metrics; stale cached values stop generating snapshots. Recovery/command diagnostics are discrete events. Clear caches between sessions.

Define freshness once using DBC cadence and configured GPS behavior. Use a monotonic clock for elapsed logging milliseconds; restore its checkpoint offset and exclude process downtime from active logging time. UTC is not reconstructed from elapsed time.

Sequence numbers identify retained metric records, not physical CAN frames or delivery order. Gaps are permitted. Persist the watermark transactionally so restart cannot reuse an identity.

Session metadata is flat: UID/name, captured start/end, state, completed laps, and persisted increasing metadata_revision. Put it in the same outbox, using a separate (session_uid, metadata_revision) identity. Older revisions cannot reopen an ended session.

Persist each session transition, corresponding metadata, and checkpoint changes atomically. Enqueue final metadata before clearing an ended session's active checkpoint. Emit a retained Lap_Completed diagnostic at each accepted crossing with the completed lap's context and exact boundary time; derive lap bounds from those events and session start.

Accept telemetry before metadata. Grafana temporarily exposes its UUID; later metadata supplies name/state. Avoid a foreign key that rejects valid early telemetry.

### One durable outbox and honest acknowledgement

Commit retained records before transport eligibility. Keep the UI independent of recording I/O, but make failed/non-durable recording visible rather than silently claiming an in-memory fallback is safe.

Use pending, broker_acked, and dropped delivery states. PUBACK confirms broker receipt, not SQL or CSV storage. Retain broker-acknowledged history for seven days within a measured storage budget; never prune pending records as ordinary history. Report quota/drop outcomes explicitly. [Current acknowledgement boundary](https://github.com/lugilugi/ect-dashboard/blob/5cdb2cc2cd860a164177c7b9c40443d07aeee169/lib/services/transport/mqtt_service.dart#L109).

Retries preserve identity, timestamps, and content. SQL accepts identical duplicates idempotently and diagnoses conflicting ones. CSV remains at-least-once: physical duplicates may occur, while canonical exports deduplicate by identity.

Local CSV reads committed journal records. Advance its durable export cursor only after the writer's documented durable flush; resume from the cursor after restart. A crash between file write and cursor update may duplicate a row but must not omit the committed record. Keep this cursor independently of the active session checkpoint. Ordinary journal pruning must not remove records that local export still needs.

Provide journal-to-SQL comparison and missing-record replay for downstream recovery. This plan does not promise unlimited outage protection or automatic phone knowledge of SQL commits. A server receipt protocol is additional architecture only if that stronger guarantee becomes a requirement.

## Clean schema

| Structure | Responsibility |
|---|---|
| Phone journal/outbox | Immutable metric/session records, unique identities, delivery/retry state, bounded retained history. |
| Phone checkpoint | Active session/lap control, elapsed offset, revision and sequence watermark; no second telemetry copy. |
| Phone export state | Local CSV recovery cursor, independent of session completion. |
| sessions | UUID/name, captured bounds, lifecycle, completed laps, metadata revision, receipt/update timestamps. |
| telemetry_raw hypertable | One metric per row: event/observed time, session/sequence/lap, signal/value/unit, source/quality/sample kind, optional shared sample identity, elapsed and receipt time. |
| Writable ingest views | Telegraf-compatible TEXT tags; validated conversion to owned UUID/integer/time types; idempotent insert and session upsert. |
| Analytical views | Session discovery, latest signal/freshness, lap bounds, energy/efficiency, fault state and aligned GPS/power calculations. |
| CSV archives | Versioned metric/session headers with identities, times, source/sample identity, quality and values. |
| Schema metadata | Current version/checksum for reproducible initialization. No old-schema adoption or backfill. |

Keep TEXT at the Telegraf binary COPY interface and cast in writable views; do not ask the plugin to encode string tags directly as UUID/integer.

The hypertable unique key includes immutable time, session_uid and seq_in_session. Time is required for a hypertable unique index. This relies on exact retry timestamps; it is not global uniqueness enforcement for a producer changing time while reusing sequence. [Timescale requirements](https://docs.timescale.com/use-timescale/latest/hypertables/hypertables-and-unique-indexes/).

COPY targets the validated view, whose trigger handles duplicates; routine redelivery must not fail an entire write. Quarantine validation failures, while operational database errors remain retryable. Prove this path, array parsing, and replay into compressed chunks on the exact tested versions.

## Commit stages

Use one implementation branch. Intermediate commits are review checkpoints, not deployments of an unmatched phone/server pair. Release the complete branch after its end-to-end gate. Each stage includes implementation, behavior-level tests, and documentation. Stage 08 has an automated host capture gate and a separate real Android/CAN gate; the latter remains explicitly pending until hardware is available.

| Commit | Proposed message | Scope and exit gate |
|---|---|---|
| 01 | docs(architecture): define clean telemetry contract and acceptance gates | Agree on payloads, schema, timestamps, CSV headers, reset scope and failure semantics. Prove the pinned Telegraf array/COPY adapter with a disposable spike. |
| 02 | feat(backend): implement clean schema and ingestion | Replace schema and Telegraf adapter; implement session revisions, dedup/validation and server CSV. Synthetic records traverse actual MQTT → SQL/CSV. |
| 03 | refactor(app): assign capture context outside MQTT | Recorder owns complete observations; session runtime owns IDs/laps/clock/sequence. Verify timestamps, freshness, GPS pairing, crossings and UI behavior. |
| 04 | feat(persistence): make journal the durable outbox | New SQLite format, transactional metrics/metadata/checkpoints, retention and recoverable local CSV. Real SQLite crash/restart tests pass. |
| 05 | refactor(mqtt): send only from the journal | One sender/serializer; bounded reads, retries, reconnect/reset/shutdown. Verify offline/replay/ack races and correct event context. |
| 06 | refactor(ops): share configuration and complete deployment parity | Shared configuration, custom credentials, schema readiness, roles, CSV HTTP, persistence and shutdown. Both Docker layouts pass actual ingestion checks. |
| 07 | fix(grafana): use shared analytical definitions | Correct present metrics/alerts, energy/laps, freshness and asynchronous alignment. Every query runs against real SQL and Grafana loads correctly. |
| 08 | test(e2e): qualify capture and both backend layouts | Extend CI and run actual-device acceptance against both layouts; save identity comparisons, runtime rates and failure evidence. |
| 09 | chore(ops): document clean cutover and recovery tools | Remove leftovers; complete exports/reconciliation, changelog and matched release/reset instructions. Release only the qualified pair. |

### 01: contract and feasibility

Document architecture/ADR, concrete event/session examples, schema/type mapping, reset/rollback limits and acceptance matrix. Define test seams before writing tests: decoder/bindings, recorder with injected clock, real SQLite transactions, MQTT adapter, Telegraf/PostgreSQL path, CSV consumers and analytical SQL.

Test the exact pinned parser rather than assuming array handling or COPY-to-view works. If the spike fails, revise the adapter before later work depends on it. [Telegraf 1.31 parser documentation](https://github.com/influxdata/telegraf/blob/v1.31.0/plugins/parsers/json_v2/README.md).

### 02: clean server implementation

Replace fresh-install SQL, remove reserved setup/lap schema, add ingest/read views and update export scripts. Replace legacy unpivot/batch parsing with one metric per array element. Add versioned server CSV headers and correct validation/shutdown behavior.

Test repeated/unknown signals, telemetry before metadata, delayed revisions, duplicates/conflicts, optional null fields, unsupported versions and malformed values. Valid records must continue after bad input. Test delayed insertion into aged/compressed chunks.

Store schema version/checksum and fail clearly on an unexpected existing schema. Do not silently drop data at ordinary startup; the release runbook performs the one authorized reset. A generic migration framework is unnecessary for this clean start.

### 03: phone capture

Introduce TelemetryRecorder.record(sample, context) around the existing event model. CAN/GPS supply observation timestamps; session runtime owns context and allocation. Add freshness/snapshot policy, GPS sibling identity and Lap_Completed events.

Test unchanged fresh inputs, stale inputs, GPS switching, wall-clock changes, monotonic elapsed time, session restart, lap transitions and discrete diagnostics. Preserve Driver/Service display, commands, USB selection and firmware protocol handling; avoid a broad DashboardState rewrite.

### 04: phone persistence

Initialize the new format once, discarding old telemetry journal/queues/checkpoint/counters. This is a reset, not row migration. Keep endpoint/USB/GPS/UI preferences. Use a format/version marker so normal restarts never repeat the reset.

Expose appendRecords, readPending, markBrokerAcknowledged, markDropped, checkpoint/watermark updates, pruning and export progress through one persistence owner. Make session transitions and metadata atomic.

Exercise real SQLite commit/crash boundaries, restart uniqueness, offline session completion, pruning, quota/disk failure, CSV export restart/rotation, reset and graceful shutdown. Surface SQLite/CSV failures separately. An APK uninstall is unnecessary.

### 05: one sender

Replace live bypass and separate replay/memory backlogs with bounded journal reads. Route records by kind. Serialize connection, publish, retry, endpoint changes, reset and shutdown. Mark only the exact successfully published records broker_acked.

Begin with 50 ms flush, at most 32 metric events and 32 KiB per packet, checked against actual serialized bytes. Measure rate, journal bytes, packet rate, UI latency and backlog drain before tuning. Do not equate the former 50,000-batch cap with a 50,000-event capacity.

Test offline capture, timeouts, reconnect callbacks, PUBACK/bookkeeping crashes, context transitions, endpoint changes, and a large backlog. Remove publish_batches, duplicate buffers and unused payload wrappers if they are no longer the real encoder.

### 06: Docker parity

Share broker/Telegraf/Grafana inputs with explicit endpoint/client-ID parameters. Fix environment precedence so custom database settings reach every consumer. Add schema readiness, bounded ingest/read-only Grafana roles, meaningful health checks, shutdown handling, and Compose CSV HTTP with read-only export access.

Keep both layouts; recommend Compose for new installations. Record actual tested digests/package pins and a version matrix. Dependency convergence is a separate documented ops decision; do not bundle unrelated major upgrades with data-model changes.

Build/run both on disposable fresh volumes with default/custom credentials and ports. Verify ingestion, datasource, CSV downloads, permissions, volume paths and restart/shutdown. compose config and pg_isready alone do not establish functionality.

### 07: Grafana and shared SQL

Use capture time and session identity, never receipt-time lower bounds. Late arrivals backfill history. Use per-signal freshness and latest observation semantics.

Use main-pack energy without double-counting the auxiliary branch; handle accumulator deltas/resets and coverage. Use current fault bitfields. Mark unsupported temperatures unavailable and disable their alerts. Keep the normal 12 V rail out of pack-voltage alerts.

Use completion/boundary events for laps. Pair GPS siblings by sample identity; use bounded alignment for independently sampled power. Missing data differs from zero. Execute all queries against real PostgreSQL and load the dashboards/alerts in the tested Grafana versions.

### 08: real-device qualification

Add container/schema/CSV integration checks to CI, retaining Flutter and generated-DBC checks. Run an actual Android APK with USB CAN/GPS through journal → MQTT → Telegraf → SQL/CSV → Grafana/HTTP, against both deployment layouts.

Implement journal-to-SQL identity comparison and missing-record replay before qualification. Reuse original identities/timestamps, and exercise the tool in the downstream failure scenarios below.

Record APK/build/signing identity, server images/schema checksum, event rate/row bytes, session UUIDs, expected identities, SQL/CSV comparisons, dashboard results and logs. Unavailable hardware/runtime checks remain explicitly unpassed. Fake transport tests or a host publisher do not replace this gate.

### 09: final cleanup and release documentation

Remove remaining legacy readers, duplicate configuration and obsolete schema/export guidance. Run the complete automated checks after cleanup; if cleanup changes runtime behavior or release binaries, repeat the affected actual-device qualification before release.

Update CHANGELOG, README, BACKEND_GUIDE, deployment README and applicable AGENTS instructions. Record exactly what resets and which matched versions are supported. Preserve Android signing identity and increasing build number. No old schema/APK downgrade compatibility is promised.

## End-to-end acceptance matrix

Use committed journal records as expected input. Compare SQL and local/server CSV by identity plus immutable content, not packet/physical-row counts. SQL has one row per valid metric identity; canonical CSV sets agree. Intentional drop/rejection tests reconcile explicit outcomes.

| Scenario | Required result |
|---|---|
| Normal USB CAN plus GPS | Immediate UI works; journal, SQL, CSV, Grafana/downloads agree on values, units, source, times and lap. |
| Session starts offline | In-budget committed records replay with original times; the complete interval appears in Grafana. |
| Kill after commit, before publish | Pending records and local CSV export recover; identity is not reused. |
| Crash after PUBACK, before bookkeeping | Safe redelivery; SQL idempotency; duplicate CSV rows retain identical identity/content. |
| End session while disconnected | Final metadata/completion survive restart; checkpoint is not cleared before durable enqueue. |
| Lap/session changes during send | Correct context; no cache or metadata leakage between sessions. |
| Reversed/delayed events, metadata last | Early telemetry is visible; older revisions cannot reopen sessions; history backfills capture time. |
| Sensor stops, MQTT stays connected | Age increases; stale snapshots stop; transport health is distinct from sensor freshness. |
| Database paused for 60 seconds | Independent CSV continues; identity sets reconcile after recovery at a recorded rate below queue limits. |
| Telegraf paused for 60 seconds; CSV restarted separately | Persistent subscriptions recover within measured limits; duplicate policy holds. |
| Clean broker/server restart | Data persists; actual ingestion resumes; readiness is more than process existence. |
| Malformed input/conflicting duplicate | Visible diagnostics/quarantine; valid traffic continues; operational errors remain retryable. |
| Quota exhaustion/abrupt broker power loss | Exact loss/recovery window and non-durable/drop outcomes recorded; reconciliation demonstrated where possible. |
| Both Docker layouts, custom credentials | Ingestion, Grafana, CSV download, permissions, initialization and shutdown work. |
| Peak input and large backlog | UI remains responsive; storage/network capacity measured; overflow is not hidden. |

Include Driver/Service switching, USB reconnect, GPS permissions/source selection, Android foreground behavior, commands and deadman behavior in the phone smoke test.

## Coordinated clean reset

Reset telemetry/session data on server and phone. Preserve unrelated configuration and data.

1. Qualify the complete matching phone/server pair in staging.
2. Stop all old phone publishers and active recording.
3. Reset this application's SQL schema/data and MQTT telemetry queues/retained messages/subscriber sessions. If the broker is shared, preserve unrelated topics, authentication and configuration; target only the documented application deployment.
4. Initialize the new schema and start the new server readers/Grafana/CSV services.
5. Start new-format CSV files; old exports are not imported into the active pipeline.
6. Install the matching APK. Its one-time reset clears old telemetry persistence and active-session state, preserving connection/USB/GPS/UI preferences.
7. Start a new session and verify a real-device round trip before normal recording resumes.

If the release fails, fix forward or reset the matched pair again. Do not mix old/new formats or promise recovery of intentionally discarded data. This explicit reset is not the general maintenance model for future schema changes.

## Documentation and checks per commit

Each commit states what changed, why, behavior/format effects and exact checks/results. Update contracts/ADRs when boundaries change; add an Unreleased changelog entry for operating/user-visible changes. Distinguish unit, container and hardware evidence.

After Dart changes run flutter pub get, flutter analyze --no-pub and flutter test --no-pub. Keep generated-CAN consistency checks. Add Python CSV, real SQLite, schema/ingestion and executable Grafana-query checks. [Current CI](https://github.com/lugilugi/ect-dashboard/blob/5cdb2cc2cd860a164177c7b9c40443d07aeee169/.github/workflows/ci.yml#L16).

**Completion:** one capture owner, one journal/outbox, one sender, one active contract, one telemetry schema, shared analytics, both Docker layouts working, and a recorded successful actual-phone-to-server run. Static review and healthy containers do not establish completion.

## Recorded implementation checkpoints

| Stage | Local commit | Outcome |
|---|---|---|
| 01 | 35f3ae0 | Architecture, ADR, contract, fixtures and acceptance gates |
| 02 | 5e543c7 | Clean v2 schema, ingestion and server CSV |
| 03 | eb93fb4 | Recorder context, elapsed clock and signal observation semantics |
| 04 | dde2ec3 | Real SQLite journal, checkpoint, watermarks and local CSV recovery |
| 05 | 1ddabaf | One journal sender and integrated runtime; old paths retired |
| 06 | c0be623 | Shared Docker inputs, bounded roles and service parity |
| 07 | 1394530 | Shared analytics and truthful unavailable/freshness behavior |
| 08 | ac4b857 | Both-layout host capture qualification, recovery tools and fixes |
| 09 | This documentation commit | Cleanup, operations, handover and clean-cutover runbook |

Automated software qualification passed; stage 08's actual Android/CAN run,
APK/signing identity and release/cutover remain explicitly pending. The user
confirmed no phone/CAN bridge is available. See verification.md for exact results
and limits; the architecture is implemented without claiming hardware readiness.
