"""Fresh-only bootstrap through PG* environment variables. Existing schema fails."""
import hashlib
import os
from pathlib import Path
import subprocess

def main():
    # Validate required configuration before creating any schema objects.
    ingest_password = os.environ['TELEGRAF_PASSWORD']
    reader_password = os.environ['GRAFANA_READER_PASSWORD']
    root = Path(__file__).resolve().parents[1]
    schema = root / 'db/schema.sql'
    subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-f', str(schema)], check=True)
    database = subprocess.check_output(['psql','-qAtc','SELECT current_database()'], text=True).strip()
    subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-v', 'db='+database,
        '-v', 'ingest_password='+ingest_password,
        '-v', 'reader_password='+reader_password,
        '-v', 'schema_hash='+hashlib.sha256(schema.read_bytes()).hexdigest(),
        '-f', str(root / 'db/scripts/bootstrap_roles.sql')], check=True)

if __name__ == '__main__':
    main()
