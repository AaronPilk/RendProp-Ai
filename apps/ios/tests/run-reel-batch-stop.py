#!/usr/bin/env python3
"""Run the source-bound batch-stop fixture and classify compiled negative controls."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-batch-stop-'))
out.mkdir(parents=True, exist_ok=True)
paths = [root / path for path in [
    'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',
    'apps/ios/Rendprop/Networking/APIClient.swift',
    'apps/ios/Rendprop/Networking/LiveAPIClient.swift',
    'apps/ios/Rendprop/Render/DriftCheck.swift',
    'apps/ios/Rendprop/Render/ReelComposer.swift',
    'apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift',
    'apps/ios/Rendprop/Models/Listing.swift',
    'apps/ios/Rendprop/Models/ListingVideo.swift',
    'apps/ios/Rendprop/Render/VideoAspectChoice.swift',
    'apps/ios/Rendprop/Render/VideoMusicContract.swift',
    'apps/ios/Rendprop/Photos/PhotoEditService.swift',
    'apps/ios/tests/ReelClipFailureTests.swift',
    'apps/ios/tests/run-reel-clip-failures.sh',
    'apps/ios/tests/run-reel-batch-stop.py',
]]
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
variants = [
    ('actual', None, None),
    ('negative-swallowed-error', '--inject-swallowed-error', 'A first-photo failure must stop without sending the remaining seven photos'),
    ('negative-lost-fallback-provenance', '--inject-lost-fallback-provenance', 'Source-photo fallbacks are counted separately from AI clips'),
    ('negative-lost-prepared-source', '--inject-lost-prepared-source', 'The actual batch loop forwards the exact saved prepared JPEG for every position'),
]
receipt = {'passed': False, 'start_source_sha256': hashes(), 'runs': [], 'limitations': [
    'Synthetic clip API and bytes. Actual ordered loop, error mapping, saved JPEG forwarding, shot metadata and paid-file parking execute.',
    'No provider call, real JPEG decode, video generation quality, camera or Photos write is proved.',
]}
try:
    for name, flag, reason in variants:
        command = ['bash', str(root / 'apps/ios/tests/run-reel-clip-failures.sh')]
        if flag:
            command.append(flag)
        run = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=240)
        log = run.stdout + run.stderr
        (out / (name + '.log')).write_text(log)
        expected = run.returncode == 0 and 'PASSED:' in log if reason is None else run.returncode != 0 and 'Precondition failed: ' + reason in log
        receipt['runs'].append({'name': name, 'exit_code': run.returncode, 'expected_result': expected, 'expected_failure': reason})
        assert expected, name + ': ' + log[-3000:]
        if reason is None:
            receipt['actual_output'] = log[log.index('PASSED:'):].strip()
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(run['expected_result'] for run in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Consumed production or fixture source changed during the batch-stop gate'
print(receipt['actual_output'])
print('PASS: 3 compiled negative controls; receipt:', out / 'receipt.json')
