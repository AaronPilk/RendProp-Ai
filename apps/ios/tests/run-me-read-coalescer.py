#!/usr/bin/env python3
"""Run the extracted production /me coalescer with closed actor-switch controls."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-me-coalescer-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
source = ROOT / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
fixture = ROOT / 'apps/ios/tests/MeReadCoalescerTests.swift'
inputs = [source, fixture, Path(__file__).resolve()]

def hashes() -> dict[str, str]:
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}

def between(text: str, first: str, last: str) -> str:
    assert text.count(first) == 1 and text.count(last) == 1
    return text[text.index(first):text.index(last)]

production = source.read_text()
method = between(production, '    private func sharedMeRead()', '\n    func cloudBrand()')
coalescer = between(production, '@MainActor final class MeReadCoalescer {', '\n// MARK: - Photo feedback')
template = fixture.read_text()
assert template.count('// EXTRACTED_SHARED_READ') == 1
assert template.count('// EXTRACTED_COALESCER') == 1
body = template.replace('// EXTRACTED_SHARED_READ', method).replace('// EXTRACTED_COALESCER', coalescer)

entry = '        guard key == Self.currentKey() else { throw CloudSyncError.identityChanged }\n        if reuseWithin > 0'
result = '            guard key == Self.currentKey(), generation == started else { throw CloudSyncError.identityChanged }\n            last ='
before_send = '            return try await self.execute(request, beforeSend: {\n                guard MeReadCoalescer.currentKey() == key else { throw CloudSyncError.identityChanged }\n            })'
assert body.count(entry) == body.count(result) == body.count(before_send) == 1
variants = [
    ('actual', body, None),
    ('negative-cached-context-fence', body.replace(entry, '        // entry context fence omitted\n        if reuseWithin > 0'), 'cached /me answer cannot cross library'),
    ('negative-completed-context-fence', body.replace(result, '            // completed context fence omitted\n            last ='), 'completed /me answer cannot cross library'),
    ('negative-before-send-fence', body.replace(before_send, '            return try await self.execute(request)'), 'library switch during token wait cannot dispatch an old /me read'),
]
receipt: dict[str, object] = {'passed': False, 'start_source_sha256': hashes(), 'runs': [],
    'scope': 'Extracted production sharedMeRead and MeReadCoalescer with closed auth, workspace and request executor; no production network or App Store calls.'}
try:
    for name, text, expected_failure in variants:
        if expected_failure is not None:
            assert text != body, f'{name}: mutation did not change the extracted production body'
        swift = out / f'{name}.swift'
        binary = out / name
        swift.write_text(text)
        compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
                                        capture_output=True, text=True, timeout=180)
        (out / f'{name}-compile.log').write_text(compile_result.stdout + compile_result.stderr)
        assert compile_result.returncode == 0, f'{name} compile: {compile_result.stderr}'
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
        output = run.stdout + run.stderr
        (out / f'{name}.log').write_text(output)
        expected = (run.returncode == 0 if expected_failure is None else
                    run.returncode != 0 and f'Precondition failed: {expected_failure}' in output)
        receipt['runs'].append({'name': name, 'exit_code': run.returncode,
                                'expected_result': expected, 'expected_failure': expected_failure,
                                'output': output[:1600]})
        binary.unlink()
        assert expected, f'{name}: {output}'
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = ('failure' not in receipt and len(receipt['runs']) == len(variants)
                         and all(row['expected_result'] for row in receipt['runs'])
                         and receipt['source_binding_matches'])
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed']
print(receipt['runs'][0]['output'])
print(f"PASSED: {len(variants)-1} guard-removal controls; {out / 'receipt.json'}")
