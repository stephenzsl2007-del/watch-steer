#!/usr/bin/env python3
"""Start the loopback browser demo with persistent per-user pairing state."""
import os
from pathlib import Path
import sys
from local_state import pairing_token

root = Path(__file__).resolve().parents[1]
if not (root / 'web/app.js').exists():
    raise SystemExit('Build the web demo first: python3 tools/build_web.py')
os.environ['WATCHSTEER_TOKEN'] = pairing_token()
os.execv(sys.executable, [sys.executable, str(root / 'backend/server.py'), *sys.argv[1:]])
