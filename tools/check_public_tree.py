#!/usr/bin/env python3
"""Check the public source selection for accidental local state. Never print matched secrets."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
try:
    names = subprocess.check_output(['git','ls-files','-z'],cwd=root,stderr=subprocess.DEVNULL).decode().split('\0')
    files = [root/n for n in names if n]
except subprocess.CalledProcessError:
    skip = {'work','desktop','dist','.git','.venv','node_modules','__pycache__','xcuserdata'}
    files = [p for p in root.rglob('*') if p.is_file() and not (set(p.relative_to(root).parts)&skip) and p != root/'web/app.js']
rules = {
    'absolute home path': rb'/(?:Users|home)/[A-Za-z0-9_.-]+/',
    'device identifier': rb'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b',
    'private signing team': rb'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}"?\s*;',
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----',
    'embedded development certificate': rb'<key>WatchSteerLocalCertificat[e]</key>',
}
forbidden = {'pairing-token','test-pairing-token','.env','.DS_Store'}
issues=[]
for p in files:
    if not p.is_file(): continue
    name=str(p.relative_to(root))
    if p.name in forbidden or p.suffix in {'.mobileprovision','.provisionprofile','.p12','.pfx','.key','.pem'}:
        issues.append((name,'private file type'))
    if p.suffix in {'.png','.jpg','.gif','.icns'}: continue
    data=p.read_bytes()
    for label,rule in rules.items():
        if re.search(rule,data): issues.append((name,label))
if issues:
    for name,label in issues: print(label+': '+name)
    sys.exit(1)
print('PASS: public source selection contains no detected local state or private identifiers')
