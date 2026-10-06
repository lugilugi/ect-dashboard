# Verification evidence

## Development baseline (6 October 2026)

- Main remains 5cdb2cc; implementation branch: codex/backend-clean-reset.
- Flutter 3.41.5 / Dart 3.11.3: 103 existing tests passed.
- Dependencies resolved from the existing lockfile; no dependency upgrades.
- Telegraf 1.31.3 Windows binary: events-array parsing preserves tags/value.
- Its object timestamp_key applies the first array timestamp to both fixture
  records. The adapter therefore carries ts_wall_utc as TEXT and casts each
  record's original timestamp in SQL; plugin gather time is receipt context only.

- TimescaleDB 2.17.2 / PostgreSQL 16.6 + Telegraf 1.31.3 + Mosquitto:
  actual MQTT â†’ COPY-to-view passed per-record time/lap, repeated identity,
  conflicting duplicate quarantine, telemetry-before-metadata, revision ordering
  and replay into a manually compressed chunk.
- CSV contract: four tests passed, including malformed neighbor isolation and
  duplicate archive identities after writer restart.

These were the initial-stage results. Final automated software qualification is recorded below; actual Android/CAN remains pending.

## Capture and journal stages

- Capture/clock stage: 106 Flutter tests passed; changed-file analysis passed.
- Journal stage: dependency resolution, full analysis (no issues), and all 111
  Flutter tests passed.
- Five real-SQLite cases cover reopening, one-time format reset, quota identity
  protection, atomic ending metadata/checkpoint clear, and local CSV recovery
  after export failure with retention protection.
- RandomAccessFile flush replaces buffered IOSink flush for cursor advancement.

The new recorder/journal are integrated into the runtime in the sender stage.
Hardware qualification is pending by user instruction: no Android/CAN hardware
is available. Do not publish or declare a hardware-qualified release.

## Stage 05 — runtime and journal sender

CAN/USB and phone GPS now record through TelemetryRecorder, preserving original
observation time and paired fix identity. Recorder owns metadata revisions,
checkpoint recovery, bounded capture, fresh snapshots and journal writes.
MqttService only batches committed records and advances delivery on broker PUBACK.
There is no direct publish path, second replay queue, or implicit RAM fallback.
Ending a recovered session offline is allowed; final metadata and checkpoint
clearing share one transaction. Old batch DTO, spool and checkpoint modules and
their fake-storage tests were replaced by real SQLite journal/pipeline tests.
Capacity is bytes; storage/CSV errors are visible in the driver status.

Checks: flutter pub get, flutter analyze --no-pub (no issues), full flutter
test --no-pub: 87 passed. New tests verify restart sequence recovery, offline
completion, exact-context retry and ACK ownership. Command/deadman and existing
UI/GPS regressions pass. Fewer tests reflect removal of the retired fake spool
implementation; this is not a comparison of physical-device coverage.

## Stage 06 — deployment parity

Single image now reuses the exact Compose TimescaleDB 2.17.2/PG16, Telegraf
1.31.3 and Grafana 11.1.4 binaries instead of independent apt package streams.
Both layouts share Telegraf and Mosquitto configuration, bounded ingest/reader
roles, fresh-only role initialization, source contract version readiness and CSV
HTTP service. PostgreSQL readiness uses TCP, after temporary initialization.
Derived SQL read models are initialized with the owned schema and reader grants.
Paho uses its current v2 callback API; CSV processes drop to nobody in Compose.
Shell sources have LF line endings (the first Windows-context image exposed
a CRLF shebang failure, repaired before the successful startup).

Evidence: disposable single container with custom DB/user/passwords was healthy;
two MQTT records became two distinct SQL times; ingest view insert allowed while
direct raw-table insert denied; independent CSV output exists. Disposable Compose
with custom credentials ingested the same fixture and served its CSV over HTTP.
Final shared-image rebuild and restart/outage qualification remain stage 08.
No installed data volume or live deployment was changed.

## Stage 07 — analytics and unavailable signals

Dashboards query shared session totals, accumulator deltas, completed-lap bounds
and lap analytics. Session discovery works before metadata and uses captured
start times. Map coordinates pair by source fix identity. Removed unsupported
auxiliary energy/temperature panels, corrected current fault bitfields and
pack-only voltage alert; live alerts use original source freshness.
Sequence gaps are explicitly provisional because delivery order is unconstrained.
Unavailable phone temperature and battery cells are NaN internally, shown as
unavailable where rendered and skipped by numeric alert evaluation.

Checks: all 53 provisioned panel, variable and alert SQL queries executed against
the disposable Compose schema. flutter analyze --no-pub: no issues; full tests:
88 passed, including unavailable-signal test. Real Grafana datasource and nonempty
analytics fixture assertions are stage 08 checks.

## Stage 08 — automated capture/server qualification

Host: Windows Docker Desktop 29.5.2; Flutter 3.41.5 / Dart 3.11.3.
Fresh, uniquely named disposable deployments use custom database/user/passwords,
random loopback ports and dedicated test volumes. No installed/live deployment
or production data is used. The helper removes its successful test resources.

Final phone checks: dependency resolution succeeded, analysis reported no issues,
and the full Flutter suite passed 91 tests with one server integration test
skipped by default. The skipped test is explicitly enabled by the Docker helper;
it executes generated CAN decoding/bindings, the actual recorder, real SQLite
and the Dart MQTT client, not a fake publisher. Ten Python tests pass (four CSV
contract tests and six operator-tool tests); Python sources compile successfully.

Qualification compares the 41 committed Dart metric records against SQL and
local/server CSV by normalized identity plus all immutable context/value fields.
Server receipt time is deliberately excluded. SQL/CSV differences, expected
archive conflicts and conflicting SQL repair attempts fail visibly. Separate
fixtures test metadata arriving late, reversed revisions, invalid neighbors,
identical/conflicting duplicate delivery, source freshness, reset-safe energy
(135 J), explicit lap completion and GPS snapshots preserving their original lap.
The CAN frame triggering a distance crossing retains the completed lap context.

All 53 provisioned panel/variable/alert SQL queries execute under grafana_reader
for lap 1 and all laps. Real Grafana datasource health and a nonempty API query
return the expected energy value. This does not establish browser rendering,
interactive time-picker behavior or actual alert notification delivery.

Operator checks cover fresh-only manual initialization and repeat refusal,
fingerprinting, reader-role snapshots, partial-export cleanup after a forced
connection error, and dry-run then publication of one missing archived metric.
The repair retains original identity and context and reconciles against SQL/CSV.

Final both-layout reports and measured outage/burst results follow. The burst is host Paho publication throughput with SQL/CSV
row reconciliation; it is not sustained Android CAN/UI capacity.

Remaining gates: Android SDK/APK build/signing, actual USB CAN/GPS phone,
permissions/background/foreground, Driver/Service use, commands/deadman on
hardware, peak target-phone backlog/UI behavior and abrupt power-loss windows.
The user explicitly left hardware qualification pending. GitHub CI has been
extended but has not run remotely; no release, tag, push or cutover is performed.

### Final custom-settings layout results

| Check | Compose | Single container |
|---|---:|---:|
| All immutable fields: Dart journal vs SQL/local CSV/server CSV | 41/41 each | 41/41 each |
| Panel/variable/alert queries (each at two lap selections) | 53 | 53 |
| Database outage | 60 seconds | 60 seconds |
| Telegraf outage | 60 seconds | 60 seconds |
| Outage/restart records reconciled in SQL/server CSV | 121/121 each | 121/121 each |
| Burst records delivered to SQL and CSV | 3,200 | 3,200 |
| Host burst publication rate | 4,014 records/s | 5,494 records/s |
| Fresh initializer/export/failure cleanup/CSV repair | passed | passed |
| CSV subscriber + clean layout restart/compressed duplicate | passed | passed |

Identity comparisons reported no missing, unexpected or conflicting records.
The Dart fixture journal occupied 73,728 bytes; the example pending JSON record
is 404 bytes (neither is a production capacity measurement). Outage loops publish
one record then sleep one second for 60 iterations; Docker invocation overhead
makes wall-clock outage duration longer than 60 seconds. CSV remains independent.
Tests stay below finite Telegraf/broker queues. PUBACK is still broker handoff;
abrupt broker/device power loss and indefinite outage protection are unqualified.

Schema SHA-256:
bf5f5e09f61f50e575e190db9de9dc17f31f1a60941c738ae0a8b9dea16714d5.
Exact runtime checks: PostgreSQL 16.6, Telegraf 1.31.3 (ecf94b12), Grafana 11.1.4,
single-image Mosquitto 2.0.20 and Paho 2.1.0. Alpine's old packaged Paho lacked
CallbackAPIVersion; the image now installs pinned Paho 2.1.0 in its CSV venv.
Schema fingerprinting and stable Supervisor start periods prevent misleading
readiness. Both layouts share the pinned core binaries/configuration.

Tested image identities (local Docker architecture):

| Image | SHA-256 |
|---|---|
| timescale/timescaledb:2.17.2-pg16 | 4e459e217f00cbb09920c34d245501e63427e6767a495de57ce76823ff280f12 |
| telegraf:1.31.3 | 05ebdd3de8c4001f5745746b022df03ea9366fd1e011accacb4af4708af85c75 |
| grafana/grafana-oss:11.1.4 | 886b56d5534e54f69a8cfcb4b8928da8fc753178a7a3d20c3f9b04b660169805 |
| eclipse-mosquitto:2.0 | 199ea8ef2e35ec2b1b37e59cfd1dbae538ed4dfa4a2251a121a52215a6248a21 |
| Built ect-backend-v2-test | 8db3bc75d7503d1f023ad94abbca0ed2de4acc2aeaf24fc68ab2fab8f73e177f |

Images/tags are not frozen release artifacts. OS/broker packages and mutable
upstream tags can change on future rebuild; record newly qualified digests.

Supplementary default-settings checks also passed both layouts: actual MQTT to
SQL/CSV and Grafana datasource health work with the supplied development defaults.
On each dedicated test volume, an intentionally wrong schema fingerprint failed
the deployment's health command after restart. Both original records and the
mismatch marker remained; initialization did not silently adopt/reset the volume.
These tests then removed their own volumes. No production reset occurred.

## Stage 09 — cleanup and handover

Retired misleading apply_migrations scripts; initialize_schema.sh/ps1 call the
fresh-only Python initializer. Export shell/PowerShell/container wrappers share
one reader-role Python implementation. Updated README, BACKEND_GUIDE, deployment
guide, contract, AGENTS, changelog and explicit paired reset/hardware runbook.
Removed the duplicate MQTT-spool reset UI and old CSV row API/format. Local
storage clear is one runtime operation preserving endpoint/USB/GPS/UI prefs.

No Android signing, version/tag, published APK, production reset or live data
change was performed. The existing release workflow keeps its signing checks
and increasing run-number build identity; it must not be treated as hardware
qualification. Both Docker layouts passed local software tests; CI execution,
APK construction and the real-phone release gate are outstanding.

Local implementation is reviewable as nine ordered commits on
codex/backend-clean-reset. Stage 08 is ac4b857; stage 09 is this documentation
commit. Keep the full branch together for qualification/cutover. Successful and
previously retained task containers/volumes were selectively removed; unrelated
Docker resources and downloaded image caches are preserved.
