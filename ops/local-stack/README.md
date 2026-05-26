# Local Backend Stack (One Command)

This folder provides a turnkey local backend stack for development:

1. TimescaleDB (PostgreSQL + Timescale extension)
2. Mosquitto
3. Telegraf (via Dockerfile)
4. Grafana

The database container (`timescaledb`) is built from a custom Dockerfile that automatically:

1. Applies all DB migrations in order.
2. Creates local ingest/reader roles.
3. Runs DB verification checks.

## Quick Start

From repository root:

```bash
docker compose -f ops/local-stack/docker-compose.yml up --build -d
```

Access points:

1. PostgreSQL/TimescaleDB: `localhost:5432`
2. Mosquitto: `localhost:1883`
3. Grafana: `http://localhost:3000` (default admin/admin unless overridden)

## Optional Environment Overrides

Copy and edit:

```bash
cp ops/local-stack/.env.example ops/local-stack/.env
```

Compose automatically loads `.env` from the same directory as the compose file.

## Verify Bootstrap

Check the database logs to confirm that all migrations and role configurations were applied successfully:

```bash
docker compose -f ops/local-stack/docker-compose.yml logs timescaledb
```

Look for the initialization output, including:

1. Migration apply completion messages.
2. `=== Summary Views ===` and `=== Sanity counts ===` outputs from the verification script.

## Telegraf DB Credentials (Local)

The stack creates local roles using:

1. `telegraf / telegraf_dev`
2. `grafana / grafana_dev`

Defined in:

1. `ops/local-stack/bootstrap/10_local_roles.sql`

## Stop and Clean Up

Stop stack:

```bash
docker compose -f ops/local-stack/docker-compose.yml down
```

Stop and remove volumes:

```bash
docker compose -f ops/local-stack/docker-compose.yml down -v
```
