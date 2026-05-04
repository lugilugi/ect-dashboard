param(
  [Parameter(Mandatory = $true)]
  [string]$Dsn
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
  throw 'psql is not available on PATH. Install PostgreSQL client tools first.'
}

$migrations = @(
  'db/migrations/001_telemetry_schema.sql',
  'db/migrations/002_indexes_policies.sql',
  'db/migrations/003_command_and_recovery_audit.sql',
  'db/migrations/004_query_performance_views.sql'
)

foreach ($migration in $migrations) {
  Write-Host "Applying $migration..."
  psql "$Dsn" -v ON_ERROR_STOP=1 -f "$migration"
}

Write-Host 'All migrations applied successfully.'
