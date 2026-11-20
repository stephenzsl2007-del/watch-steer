#!/usr/bin/env python3
"""Build a development Mac receiver bundle, without adding third-party packages."""
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
subprocess.run(['python3',str(root/'tools/build_web.py')],check=True)
app = root/'desktop/WatchSteer 接收器.app'
contents = app/'Contents'
(contents/'MacOS').mkdir(parents=True, exist_ok=True)
resources = contents/'Resources'
resources.mkdir(exist_ok=True)
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-O',
    '-file-prefix-map',str(root)+'=WatchSteer','-debug-prefix-map',str(root)+'=WatchSteer',
    '-target',('arm64' if platform.machine() == 'arm64' else 'x86_64')+'-apple-macos14.0',
    '-module-cache-path',str(root/'work/swift-cache'),
    str(root/'shared/BLEProtocol.swift'),str(root/'mac/MacReceiver.swift'),
    '-o',str(contents/'MacOS/WatchSteerMac')],check=True)
for name in ['backend','web']:
    shutil.copytree(root/name, resources/name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
info = dict(CFBundleExecutable='WatchSteerMac',CFBundleIdentifier='com.watchsteer.local.mac',
    CFBundleName='WatchSteer 接收器',CFBundleDisplayName='WatchSteer 接收器',CFBundlePackageType='APPL',
    CFBundleVersion='1',CFBundleShortVersionString='0.1.0',LSMinimumSystemVersion='14.0',
    NSBluetoothAlwaysUsageDescription='通过蓝牙直接接收你手表的转向值，用于本机网页。',
    NSHighResolutionCapable=True)
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)
