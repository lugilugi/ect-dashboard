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

echo "Applying db/schema.sql..."
psql "$DSN" -v ON_ERROR_STOP=1 -f db/schema.sql

echo "All schema applied successfully."
