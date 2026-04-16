# Grafana Ops Notes

This folder contains baseline dashboard scaffolding for Phase 6.

## Files

- [dashboards/session_overview.json](dashboards/session_overview.json): Session-first operational view.
- [dashboards/lap_analysis.json](dashboards/lap_analysis.json): Lap-level comparison and confidence analysis.
- [provisioning/datasources/timescaledb.yml](provisioning/datasources/timescaledb.yml): Auto-provisioned datasource.
- [provisioning/dashboards/dashboards.yml](provisioning/dashboards/dashboards.yml): Auto-provisioned dashboard loader.

## Datasource Assumption

Both dashboards target datasource UID `timescaledb`.

The provisioning datasource file also creates this UID by default:

- [provisioning/datasources/timescaledb.yml](provisioning/datasources/timescaledb.yml)

If you use a different UID, update both dashboard JSON files accordingly.

## Auto-Provisioning (Recommended)

Mount the repo folders into Grafana:

```yaml
volumes:
	- ./ops/grafana/provisioning:/etc/grafana/provisioning
	- ./ops/grafana/dashboards:/var/lib/grafana/dashboards
```

Then start/restart Grafana. Dashboards are loaded under folder `ECT`.

## Manual Import (Alternative)

Use this when provisioning mounts are unavailable.

1. Open Grafana: `Dashboards -> New -> Import`.
2. Upload each JSON file from `ops/grafana/dashboards/`.
3. Bind to your PostgreSQL datasource.
4. Save the dashboards.

## Variable Behavior

- `session_id`: selected from `telemetry.sessions` ordered by latest start/create time.
- `lap_number` (lap analysis dashboard): filtered by selected session; `All` uses `-1` sentinel.

## Validation Checklist

1. `session_id` dropdown shows recent sessions.
2. Session overview timeline renders `Speed_Kmh` by wall time.
3. Lap analysis overlay shows per-lap speed traces.
4. Lap metadata and confidence tables populate from `telemetry.laps` and `telemetry.lap_events`.
5. Recovery and command audit tables show rows when those events are ingested.
