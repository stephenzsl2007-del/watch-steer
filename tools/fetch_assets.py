#!/usr/bin/env python3
"""Restore original CC0 maps from the recorded, hash-checked Poly Haven URLs."""
import hashlib
import json
from pathlib import Path
import urllib.request
root = Path(__file__).resolve().parents[1] / 'web/assets'
for item in json.loads((root / 'sources.json').read_text()):
    path = root / item['file']
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256']:
        continue
    if not item['url'].startswith('https://dl.polyhaven.org/file/ph-assets/'):
        raise ValueError('Unexpected asset source')
    with urllib.request.urlopen(item['url'], timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('Asset checksum mismatch: ' + item['file'])
    path.write_bytes(data)
    print('Restored', item['file'])
print('All original material maps verified.')
