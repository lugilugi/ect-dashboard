# export_to_csv.ps1
# Connects to the TimescaleDB instance and exports all telemetry tables to CSV.
# This script is designed to run locally using Docker or fallback to host psql.

$ErrorActionPreference = "Stop"

# Target export directory relative to repository root
$ExportDir = "./csv_exports"
if (!(Test-Path $ExportDir)) {
    New-Item -ItemType Directory -Path $ExportDir | Out-Null
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "    ECT Telemetry TimescaleDB -> CSV Export" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$tables = @("sessions", "laps", "telemetry_raw")

# Check if docker is running and ect-timescaledb container is active
$dockerRunning = $false
try {
    $containers = docker ps --format '{{.Names}}'
    if ($containers -contains "ect-timescaledb") {
        $dockerRunning = $true
    }
} catch {
    # Docker not in PATH or not running
}

if ($dockerRunning) {
    Write-Host "Active docker container 'ect-timescaledb' found. Exporting using Docker..."
    Write-Host "Exporting to: $ExportDir/"
    Write-Host "--------------------------------------------------"

    foreach ($table in $tables) {
        Write-Host "Exporting $table..."
        # Run docker exec and redirect output to local file
        docker exec -i ect-timescaledb psql -U postgres -d telemetry -c "\copy (SELECT * FROM $table) TO STDOUT WITH CSV HEADER" | Out-File -FilePath "$ExportDir/$table.csv" -Encoding utf8
    }
} else {
    # Fallback to local psql
    $DbHost = if ($env:TS_HOST) { $env:TS_HOST } else { "localhost" }
    $DbPort = if ($env:TS_PORT) { $env:TS_PORT } else { "5432" }
    $DbName = if ($env:TS_DB) { $env:TS_DB } else { "telemetry" }
    $DbUser = if ($env:TS_USER) { $env:TS_USER } else { "postgres" }
    $env:PGPASSWORD = if ($env:TS_PASSWORD) { $env:TS_PASSWORD } else { "postgres" }

    Write-Host "No active docker container 'ect-timescaledb' found. Falling back to local psql..."
    Write-Host "Connecting to: postgres://${DbUser}@${DbHost}:${DbPort}/${DbName}"
    Write-Host "Exporting to: $ExportDir/"
    Write-Host "--------------------------------------------------"

    foreach ($table in $tables) {
        Write-Host "Exporting $table..."
        psql -h $DbHost -p $DbPort -d $DbName -U $DbUser -c "\copy (SELECT * FROM $table) TO '$ExportDir/$table.csv' WITH CSV HEADER"
    }
}

Write-Host "--------------------------------------------------"
Write-Host "Success! All CSV files written to $ExportDir/" -ForegroundColor Green
Write-Host "=================================================="
