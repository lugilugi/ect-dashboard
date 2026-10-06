# Backend deployment inputs

Both layouts share the broker/ingest configuration and CSV code here.
The single Dockerfile assembles pinned TimescaleDB/Telegraf/Grafana components
under Supervisor/tini. Compose runs them separately and serves CSV read-only.

See [backend operations](../../BACKEND_GUIDE.md) for setup, environment, roles,
schema readiness/reset/recovery and checks. See
[verification](../../docs/implementation/verification.md) for evidence and limits.
