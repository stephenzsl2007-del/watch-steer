#!/usr/bin/env python3
"""Build an ad-hoc signed standalone app on an Apple Silicon Mac with Python 3.12."""
import importlib.metadata
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
if platform.system() != 'Darwin' or platform.machine() != 'arm64' or sys.version_info[:2] != (3, 12):
    raise SystemExit('The standalone release build requires Apple Silicon macOS and Python 3.12')
work = root / 'work/standalone'
work.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(root/'tools/build_web.py')], check=True)
subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--name', 'WatchSteerService', '--distpath', str(work/'dist'), '--workpath', str(work/'build'), '--specpath', str(work), str(root/'backend/server.py')], check=True)
app = root/'desktop/WatchSteer.app'
if app.exists(): shutil.rmtree(app)
contents = app/'Contents'
resources = contents/'Resources'
(contents/'MacOS').mkdir(parents=True)
resources.mkdir()
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-O',
    '-target','arm64-apple-macos14.0','-file-prefix-map',str(root)+'=WatchSteer',
    '-debug-prefix-map',str(root)+'=WatchSteer','-module-cache-path',str(work/'swift-cache'),
    str(root/'shared/BLEProtocol.swift'),str(root/'mac/MacReceiver.swift'),
    '-o',str(contents/'MacOS/WatchSteerMac')],check=True)
for source,name in [(work/'dist/WatchSteerService','service'),(root/'web','web')]:
    shutil.copytree(source, resources/name, symlinks=True,
                    ignore=shutil.ignore_patterns('.DS_Store','__pycache__','*.pyc'))
for p in (resources/'web/assets').glob('*.jpg'): p.unlink()
iconset=work/'WatchSteer.iconset'; iconset.mkdir(exist_ok=True)
subprocess.run(['xcrun','swift',str(root/'tools/draw_app_icon.swift'),str(work/'icon.png')],check=True)
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
        subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(work/'icon.png'),'--out',str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(resources/'WatchSteer.icns')],check=True)
info=dict(CFBundleExecutable='WatchSteerMac',CFBundleIdentifier='com.watchsteer.local.mac',
    CFBundleName='WatchSteer',CFBundleDisplayName='WatchSteer',CFBundlePackageType='APPL',
    CFBundleVersion='1',CFBundleShortVersionString='0.1.0',CFBundleIconFile='WatchSteer.icns',
    LSMinimumSystemVersion='14.0',NSBluetoothAlwaysUsageDescription='Receive wrist steering from Apple Watch for the local driving demo.',
    NSHighResolutionCapable=True,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
licenses=resources/'Licenses';licenses.mkdir()
for source,name in [(root/'LICENSE','WatchSteer-MIT.txt'),(root/'THIRD_PARTY_NOTICES.md','THIRD_PARTY_NOTICES.md'),
                    (root/'web/vendor/THREE-LICENSE.txt','Three-MIT.txt'),
                    (root/'web/vendor/CANNON-LICENSE.txt','cannon-es-MIT.txt')]:
    shutil.copy2(source,licenses/name)
for source in (root/'licenses').iterdir():
    if source.is_file(): shutil.copy2(source,licenses/source.name)
dist=importlib.metadata.distribution('pyinstaller')
copying=next((dist.locate_file(p) for p in dist.files if str(p).endswith('licenses/COPYING.txt')),None)
if copying is None: raise SystemExit('PyInstaller license is missing')
shutil.copy2(copying,licenses/'PyInstaller-COPYING.txt')
subprocess.run(['xattr','-cr',str(app)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print(app)
