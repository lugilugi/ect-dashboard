"""Read-only SQL snapshots; shared by container, shell and PowerShell wrappers."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(os.environ.get("EXPORT_DIR", "csv_exports")))
    args = parser.parse_args()
    env = dict(os.environ)
    defaults = {"PGHOST": env.get("TS_HOST", "127.0.0.1"),
                "PGPORT": env.get("TS_PORT", "5432"),
                "PGDATABASE": env.get("POSTGRES_DB", env.get("TS_DB", "telemetry")),
                "PGUSER": env.get("TS_DATASOURCE_USER", "grafana_reader"),
                "PGPASSWORD": env.get("TS_DATASOURCE_PASSWORD", env.get("GRAFANA_READER_PASSWORD", "grafana"))}
    for key, value in defaults.items():
        env.setdefault(key, value)
    args.output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    for relation in ["sessions", "lap_bounds", "telemetry_samples", "ingest_rejections"]:
        target = args.output / (relation + "_" + stamp + ".csv")
        temporary = target.with_suffix(".tmp")
        try:
            with temporary.open("wb") as stream:
                subprocess.run(["psql", "-q", "-v", "ON_ERROR_STOP=1", "-c",
                    "SET TIME ZONE 'UTC'; COPY (SELECT * FROM " + relation + ") TO STDOUT WITH CSV HEADER"],
                    env=env, stdout=stream, check=True)
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
        print(target)

if __name__ == "__main__":
    main()
