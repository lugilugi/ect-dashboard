# ECT Backend - Single Container

The whole telemetry backend (TimescaleDB + Mosquitto + Telegraf + Grafana) in
one image, orchestrated by supervisord. No compose, no multi-service wiring -
just build and run:

```bash
# from the repository root (the whole repo is the build context)
docker build -t ect-backend -f ops/backend/Dockerfile .
docker run -d --name ect-backend \
  -p 1883:1883 -p 5432:5432 -p 3000:3000 \
  -e POSTGRES_PASSWORD=changeme \
  -e GRAFANA_ADMIN_PASSWORD=changeme \
  ect-backend
```

Then:

- MQTT broker at `mqtt://<host>:1883` (topic `telemetry/eco_archers/events`)
- Grafana at `http://<host>:3000` (admin / your password)
- TimescaleDB at `postgres://<host>:5432/telemetry`

Everything is configurable with `-e` environment variables - see
[BACKEND_GUIDE.md](../../BACKEND_GUIDE.md) for the full reference, the CAN
signal how-to, and troubleshooting.

## Files

- `Dockerfile` - the whole stack in one image
- `supervisord.conf` - runs postgres, mosquitto, telegraf, grafana
- `mosquitto.conf` - broker config (anonymous, local dev)
- `telegraf.conf` - MQTT -> TimescaleDB ingest (env-driven topics)

Prefer separate containers? Use `ops/local-stack/docker-compose.yml` instead.
