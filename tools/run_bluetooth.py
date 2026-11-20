#!/usr/bin/env python3
"""Build and launch the native receiver using the current user's pairing state."""
import os
from pathlib import Path
import subprocess
import sys
from local_state import state_directory

root = Path(__file__).resolve().parents[1]
app = root / 'desktop/WatchSteer 接收器.app'
if not app.exists():
    subprocess.run([sys.executable, str(root / 'tools/build_mac.py')], check=True)
env = os.environ.copy()
env['WATCHSTEER_STATE_DIR'] = str(state_directory())
env['WATCHSTEER_PYTHON'] = sys.executable
env.setdefault('WATCHSTEER_BLE_AUTOSTART', '1')
subprocess.run([str(app / 'Contents/MacOS/WatchSteerMac')], env=env, check=True)
