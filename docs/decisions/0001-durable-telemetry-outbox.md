# ADR 0001: one immutable journal and one sender

Status: accepted for implementation.

Replace decoded-event and serialized-batch persistence with one SQLite journal.
Metrics and session metadata share pending, broker_acked and dropped states.
Session transitions, metadata and checkpoints commit atomically. One sender
publishes bounded pending reads, without bypassing persistence.

Keep seven days of broker-acknowledged history for reconciliation within a
measured storage budget. Pruning protects pending and unexported records.
Report storage failure/quota exhaustion instead of silently falling back to RAM.

Keep local and independent server CSV recovery coverage. Both are at-least-once;
canonical exports/verification deduplicate identities.

This release intentionally resets old telemetry/session persistence. Do not
build legacy readers, backfills or conversion adapters. Preserve connectivity,
USB, GPS and UI preferences.

Retries retain identity/capture time; SQL inserts idempotently. Asynchronous
sensors and late metadata remain supported. Live UI does not await I/O.

MQTT acknowledgement is not a SQL commit acknowledgement. Queues and crash
windows are finite. Reconcile retained journal records after downstream failures.
Automatic SQL receipts require a separate protocol outside this decision.

Deploy a matching pair after qualification. Hardware qualification is pending
until a real Android phone and CAN bridge are available. Development tests must
not reset installed data.
