$ErrorActionPreference = 'Stop'
python "$PSScriptRoot/../../tools/initialize_backend.py"
if ($LASTEXITCODE -ne 0) { throw 'Fresh schema initialization failed.' }
