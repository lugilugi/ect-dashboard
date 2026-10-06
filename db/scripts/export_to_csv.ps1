$ErrorActionPreference = 'Stop'
python "$PSScriptRoot/../../ops/backend/export_snapshot.py" @args
if ($LASTEXITCODE -ne 0) { throw 'SQL export failed; partial files were removed.' }
