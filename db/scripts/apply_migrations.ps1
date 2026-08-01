param(
  [Parameter(Mandatory = $true)]
  [string]$Dsn
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
  throw 'psql is not available on PATH. Install PostgreSQL client tools first.'
}

Write-Host 'Applying db/schema.sql...'
psql "$Dsn" -v ON_ERROR_STOP=1 -f db/schema.sql

Write-Host 'All schema applied successfully.'
