import os
import sys
from pathlib import Path

root = Path(os.environ.get('EXPORT_DIR', '/exports'))
if sys.argv[-1].endswith('csv_streamer.py'):
    root.mkdir(parents=True, exist_ok=True)
    os.chown(root, 65534, 65534)
os.setgid(65534)
os.setuid(65534)
os.execvp(sys.argv[1], sys.argv[1:])
