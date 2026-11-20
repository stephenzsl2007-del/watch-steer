#!/usr/bin/env python3
"""Bundle classic scripts and original material maps; HTTP and file previews need no CDN."""
import base64
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
files = ['vendor/three.min.js', 'highland-route.js', 'vehicle-physics.js', 'car-models.js', 'driving.js', 'telemetry.js']
assets = {}
for item in json.loads((root / 'web/assets/sources.json').read_text()):
    data = (root / 'web/assets' / item['file']).read_bytes()
    if hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('Material checksum mismatch: ' + item['file'])
    assets[item['file']] = 'data:image/jpeg;base64,' + base64.b64encode(data).decode('ascii')
asset_bundle = 'window.WatchSteerAssets=' + json.dumps(assets, separators=(',', ':')) + ';\n'
engine = "(function(){var exports={};var require=function(id){if(id==='perf_hooks')return {performance:window.performance};throw new Error('Unsupported physics dependency: '+id);};\n"
engine += (root / 'web/vendor/cannon-es.cjs.js').read_text() + '\nwindow.CANNON=exports;})();'
(root / 'web/app.js').write_text(asset_bundle + engine + '\n;\n' + '\n;\n'.join((root / 'web' / p).read_text() for p in files))
print('Built local highland scene, physics and telemetry; verified', len(assets), 'material maps.')
