#!/bin/bash
# export_to_csv.sh
# Connects to the TimescaleDB instance and exports all telemetry tables to CSV.
# This script is designed to run locally using Docker or fallback to host psql.

set -e

# Target export directory relative to repository root
EXPORT_DIR="./csv_exports"
mkdir -p "$EXPORT_DIR"

echo "=================================================="
echo "    ECT Telemetry TimescaleDB -> CSV Export"
echo "=================================================="

tables=("sessions" "laps" "telemetry_raw")

# Check if docker is running and ect-timescaledb container is active
if docker ps --format '{{.Names}}' | grep -q "^ect-timescaledb$"; then
  echo "Active docker container 'ect-timescaledb' found. Exporting using Docker..."
  echo "Exporting to: $EXPORT_DIR/"
  echo "--------------------------------------------------"
  for table in "${tables[@]}"; do
    echo "Exporting $table..."
    docker exec -i ect-timescaledb psql -U postgres -d telemetry -c "\copy (SELECT * FROM $table) TO STDOUT WITH CSV HEADER" > "$EXPORT_DIR/$table.csv"
  done
else
  # Fallback to local psql
  DB_HOST="${TS_HOST:-localhost}"
  DB_PORT="${TS_PORT:-5432}"
  DB_NAME="${TS_DB:-telemetry}"
  DB_USER="${TS_USER:-postgres}"
  export PGPASSWORD="${TS_PASSWORD:-postgres}"

  echo "No active docker container 'ect-timescaledb' found. Falling back to local psql..."
  echo "Connecting to: postgres://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
  echo "Exporting to: $EXPORT_DIR/"
  echo "--------------------------------------------------"
  for table in "${tables[@]}"; do
    echo "Exporting $table..."
    psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -c "\copy (SELECT * FROM $table) TO '$EXPORT_DIR/$table.csv' WITH CSV HEADER"
  done
fi

echo "--------------------------------------------------"
echo "Success! All CSV files written to $EXPORT_DIR/"
echo "=================================================="
