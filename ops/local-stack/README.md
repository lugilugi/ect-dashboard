# Local Backend Stack (One Command)

This folder provides a turnkey local backend stack for development:

1. TimescaleDB (PostgreSQL + Timescale extension)
2. Mosquitto
3. Telegraf (via Dockerfile)
4. Grafana

The stack also runs a one-shot `db-bootstrap` service that:

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

Check bootstrap logs:

```bash
docker compose -f ops/local-stack/docker-compose.yml logs db-bootstrap
```

Look for:

1. Migration apply completion.
2. `Database bootstrap complete.`

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
