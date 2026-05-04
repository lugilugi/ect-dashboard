#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <postgres-dsn>"
  exit 1
fi

DSN="$1"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is not available on PATH. Install PostgreSQL client tools first."
  exit 1
fi

migrations=(
  "db/migrations/001_telemetry_schema.sql"
  "db/migrations/002_indexes_policies.sql"
  "db/migrations/003_command_and_recovery_audit.sql"
  "db/migrations/004_query_performance_views.sql"
)

for migration in "${migrations[@]}"; do
  echo "Applying ${migration}..."
  psql "$DSN" -v ON_ERROR_STOP=1 -f "$migration"
done

echo "All migrations applied successfully."
