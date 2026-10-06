#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/../../ops/backend/export_snapshot.py" "$@"
