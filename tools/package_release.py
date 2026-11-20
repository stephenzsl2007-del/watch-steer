#!/usr/bin/env python3
"""Package a clean committed source tree and a separately built, verified Mac app."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--app', type=Path, required=True)
p.add_argument('--output', type=Path, default=root/'dist')
p.add_argument('--version', default='v0.1.0-alpha.1')
a = p.parse_args()
if subprocess.check_output(['git','status','--porcelain'],cwd=root):
    p.error('Commit the public source changes before packaging')
subprocess.run(['python3',str(root/'tools/check_public_tree.py')],check=True)
app=a.app.resolve()
if app.name!='WatchSteer.app' or not app.is_dir(): p.error('Expected the clean WatchSteer.app bundle')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
a.output.mkdir(parents=True,exist_ok=True)
source=a.output/('WatchSteer-'+a.version+'-source.zip')
subprocess.run(['git','archive','--format=zip','--prefix=watch-steer-'+a.version+'/',
                '--output',str(source.resolve()),'HEAD'],cwd=root,check=True)
dmg=a.output/('WatchSteer-'+a.version+'-macos-arm64.dmg')
with tempfile.TemporaryDirectory(prefix='watchsteer-dmg-') as temporary:
    folder=Path(temporary)
    shutil.copytree(app,folder/app.name,symlinks=True)
    (folder/'Applications').symlink_to('/Applications')
    subprocess.run(['xattr','-cr',str(folder)],check=True)
    subprocess.run(['hdiutil','create','-volname','WatchSteer','-srcfolder',str(folder),
                    '-ov','-format','UDZO',str(dmg.resolve())],check=True)
manifest=a.output/'SHA256SUMS.txt'
manifest.write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n' for path in [dmg,source]))
print('Created source ZIP, Apple Silicon DMG and SHA-256 manifest in',a.output)
