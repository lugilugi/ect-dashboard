#!/bin/sh
set -eu
exec python3 /usr/local/bin/export_snapshot.py "$@"
