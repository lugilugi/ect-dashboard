# Telemetry Backend Docker Guide

This guide provides a comprehensive overview of setting up, understanding, and utilizing the telemetry backend stack for the ECT Dashboard using Docker.

## 1. Architecture Overview

The backend stack is designed to ingest high-frequency telemetry data from the Flutter application (or physical ESP32 devices) and store it efficiently for real-time visualization and historical analysis.

The architecture consists of the following components running as Docker containers:

*   **Mosquitto (MQTT Broker):** Acts as the central nervous system. The Flutter dashboard (or ESP32 hardware) publishes telemetry data to MQTT topics.
*   **Telegraf:** The ingestion agent. It subscribes to the MQTT topics, formats the incoming JSON or raw payload, and writes it directly to the database.
*   **TimescaleDB (PostgreSQL):** A time-series optimized SQL database. It stores the raw telemetry events, manages data retention policies, and provides materialized views for fast dashboard queries (like lap summaries).
*   **Grafana:** A visualization tool used for operational monitoring, querying historical data, and building custom analytics dashboards independent of the Flutter app.
*   **DB-Bootstrap:** A temporary container that automatically applies all SQL migrations, sets up database schema, provisions local roles, and verifies the setup upon startup.

## 2. Prerequisites

To run the backend, you need the following installed on your machine:
*   [Docker](https://docs.docker.com/get-docker/)
*   [Docker Compose](https://docs.docker.com/compose/install/)

## 3. Setting Up the Backend

The entire stack is configured via Docker Compose in the `ops/local-stack` directory.

### Step 1: Environment Variables (Optional)
A default `.env.example` file is provided. If you want to customize ports or passwords, copy it and edit:
```bash
cp ops/local-stack/.env.example ops/local-stack/.env
```
*(By default, the stack uses standard ports and default development credentials, so this step can be skipped for local development).*

### Step 2: Start the Stack
Run the following command from the **root of the repository**:
```bash
docker compose -f ops/local-stack/docker-compose.yml up --build -d
```
The `-d` flag runs the containers in detached mode (in the background).

### Step 3: Verify the Bootstrap Process
When the stack starts for the first time, the `db-bootstrap` service automatically runs all necessary SQL migrations and initializes the schema. Verify that it completed successfully:
```bash
docker compose -f ops/local-stack/docker-compose.yml logs db-bootstrap
```
You should see output ending with:
`Database bootstrap complete.`

## 4. Utilizing the Backend

Once the stack is running, the services are exposed on your local machine.

### Access Points & Credentials

| Service | Address | Default Credentials | Description |
| :--- | :--- | :--- | :--- |
| **TimescaleDB** | `localhost:5432` | `postgres` / `postgres` | Use any PostgreSQL client (e.g., pgAdmin, DBeaver) to explore the `telemetry` database. |
| **Mosquitto** | `localhost:1883` | None (Unauthenticated) | Standard MQTT broker port. |
| **Grafana** | `http://localhost:3000` | `admin` / `admin` | Web interface for analytics. |

### Data Flow & Ingestion

1.  **Publishing Data:** Your client (e.g., ESP32 or the Flutter app using `mqtt_client`) publishes telemetry messages to Mosquitto on port `1883`. The topic is typically `telemetry/eco_archers/events`.
2.  **Processing:** Telegraf is listening to that topic. Once a message arrives, Telegraf processes it based on its configuration (`ops/telegraf/telegraf.conf`) and converts it into SQL `INSERT` statements.
3.  **Storage:** Telegraf uses the `telegraf` role (password: `telegraf_dev`) to write directly into TimescaleDB's hypertables in the `telemetry` schema.

### Writing Custom Queries

Connect to TimescaleDB (`localhost:5432`) and query the time-series data. 
The system automatically creates several useful summary views:

*   **`telemetry.session_summary_v1`**: Overview of each running or completed session.
*   **`telemetry.lap_summary_v1`**: Aggregated metrics per lap.
*   **`telemetry.latest_metric_values_v1`**: Extremely fast lookup for the most recent value of any metric (Speed, Voltage, etc.) for a given session.

**Example Query:** Fetching the latest speed for a specific session:
```sql
SELECT *
FROM telemetry.latest_metric_values_v1
WHERE metric_key = 'Speed_Kmh';
```

## 5. Operations and Maintenance

### Viewing Logs
To see what Telegraf or TimescaleDB is doing:
```bash
# View all logs
docker compose -f ops/local-stack/docker-compose.yml logs -f

# View Telegraf logs only
docker compose -f ops/local-stack/docker-compose.yml logs -f telegraf
```

### Stopping the Stack
To stop the containers without losing your database data:
```bash
docker compose -f ops/local-stack/docker-compose.yml down
```

### Full Reset (Wipe Data)
If you need to completely clear the database and start fresh, bring down the stack and remove the Docker volumes:
```bash
docker compose -f ops/local-stack/docker-compose.yml down -v
```

## 6. Common Troubleshooting

1.  **"db-bootstrap" fails or exits with an error:**
    *   This usually happens if TimescaleDB wasn't fully ready. Try running `docker compose -f ops/local-stack/docker-compose.yml restart db-bootstrap`.
2.  **No data appearing in TimescaleDB or Grafana:**
    *   Verify Mosquitto is receiving messages. You can use a tool like MQTT Explorer to subscribe to `#` on `localhost:1883`.
    *   Check Telegraf logs for parsing errors: `docker compose -f ops/local-stack/docker-compose.yml logs telegraf`.
3.  **Port conflicts (e.g., `5432` already in use):**
    *   If you already have a local PostgreSQL instance running, copy the `.env.example` file and change `TS_PORT` to something else (e.g., `5433`).
