#!/usr/bin/env python3
"""Synthetic HTTP sender. Not a measurement of Apple Watch or motion latency."""
import argparse
import getpass
import json
import math
import os
import statistics
import time
import urllib.request
import uuid

p = argparse.ArgumentParser()
p.add_argument('--url', default='http://127.0.0.1:8765')
p.add_argument('--seconds', type=float, default=10)
p.add_argument('--hz', type=float, default=20)
args = p.parse_args()
if not 0 < args.hz <= 50 or not 0 < args.seconds <= 600:
    p.error('hz must be 0..50 and seconds 0..600')
token = os.environ.get('WATCHSTEER_TOKEN') or getpass.getpass('Pairing token: ')
session = str(uuid.uuid4())
start = time.monotonic()
rtts = []
seq = 0
while time.monotonic() - start < args.seconds:
    tick = time.monotonic()
    seq += 1
    angle = math.sin((tick-start)*1.5) * 45
    sample = dict(session=session, seq=seq, steering=angle/60, angleDeg=angle,
                  sampleHz=args.hz, sampleAgeMs=0, rttMs=rtts[-1] if rtts else 0, calibrated=True)
    request = urllib.request.Request(args.url.rstrip('/')+'/api/steer',
        data=json.dumps(sample).encode(), method='POST',
        headers={'Authorization': 'Bearer '+token, 'Content-Type':'application/json'})
    with urllib.request.urlopen(request, timeout=3) as response:
        ack = json.load(response)
        assert ack['ok'] and ack['seq'] == seq
    rtts.append((time.monotonic()-tick)*1000)
    time.sleep(max(0, 1/args.hz - (time.monotonic()-tick)))
ordered = sorted(rtts)
print(json.dumps(dict(kind='synthetic_HTTP_only', count=len(rtts), achievedHz=len(rtts)/(time.monotonic()-start),
    p50Ms=statistics.median(rtts), p95Ms=ordered[max(0, math.ceil(len(rtts)*.95)-1)],
    maxMs=max(rtts)), indent=2))
