#!/usr/bin/env python3
"""Read-only HTTP file server for the server-side CSV exports.

Serves $EXPORT_DIR (default /var/lib/ect-backend/exports) as a directory
listing so exports are downloadable from the host browser:
    http://<backend-host>:8080/
No query execution over HTTP - it only serves files that export_to_csv.sh
or the independent logger already wrote.

Security: read-only, no auth, bind 0.0.0.0 for container port mapping. Only
expose it in trusted networks (same hardening guidance as Mosquitto).
"""

import http.server
import os
from pathlib import Path

PORT = int(os.environ.get("CSV_SERVER_PORT", "8080"))
ROOT = os.environ.get("EXPORT_DIR", "/var/lib/ect-backend/exports")
os.makedirs(ROOT, exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def translate_path(self, path):
        translated = Path(super().translate_path(path)).resolve()
        if not translated.is_relative_to(Path(ROOT).resolve()):
            return str(Path(ROOT) / '.forbidden')
        return str(translated)

    def log_message(self, fmt, *args):
        pass  # keep container logs quiet


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
