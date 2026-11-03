#!/usr/bin/env python3
"""Import only measured, matching Dell calibration from this local diagnostic run."""
import json
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
if destination.exists():
    destination.unlink()
try:
    config = json.loads((source / 'config.json').read_text())
    observations = [json.loads(line) for line in (source / 'observations.jsonl').read_text().splitlines()]
    experiments = [json.loads(line) for line in (source / 'experiments.jsonl').read_text().splitlines()]
except (FileNotFoundError, ValueError):
    sys.exit(0)

version = subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip().split('.')
version += ['0'] * (3 - len(version))
profile = {'schema': 1, 'dellUUID': config['dell']['uuid'], 'zowieUUID': config['zowie']['uuid'],
           'dellSerial': config['ddc']['serial'], 'edid': config['ddc']['edid'],
           'osVersion': '.'.join(version), 'strategy': 'disable'}
for label, key in [('usb-c', 'usbC'), ('hdmi', 'hdmi')]:
    selected = [x for x in observations if x['label'] == label and x['phase'] == 'extended']
    if not selected:
        continue
    samples = [x for x in selected if x['run'] == selected[-1]['run']]
    values = {x.get('reading', {}).get('current') for x in samples}
    if len(samples) < 3 or len(values) != 1 or None in values:
        continue
    if not all(x.get('reading', {}).get('valid') and not x.get('error') and
               x['reading']['device']['serial'] == config['ddc']['serial'] and
               x['reading']['device']['edid'] == config['ddc']['edid'] for x in samples):
        continue
    value = next(iter(values))
    tests = [x for x in experiments if x['label'] == label and x['mode'] == 'disable']
    if not tests:
        continue
    test = tests[-1]
    if not (test.get('mutationObserved') and test.get('restored') and test.get('ddcReadable') and not test.get('error') and
            (test.get('protectedUnchanged') or test.get('protectedTimingAdjusted')) and
            test['before']['configuration']['dell'] == config['dell'] and
            test['before']['configuration']['ddc']['serial'] == config['ddc']['serial'] and
            test.get('readings') and all(x.get('reading', {}).get('current') == value and x.get('reading', {}).get('valid') for x in test['readings'])):
        continue
    profile[key] = {'value': value, 'verified': True, 'date': test['date']}
if profile.get('usbC', {}).get('value') == profile.get('hdmi', {}).get('value'):
    profile.pop('hdmi', None)
if profile.get('usbC') or profile.get('hdmi'):
    destination.write_text(json.dumps(profile, indent=2) + '\n')
