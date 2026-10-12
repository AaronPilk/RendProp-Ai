#!/usr/bin/env python3
"""Capture the real QC serializer, request builder and executor's HTTP body."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', '--out', dest='evidence_dir', type=Path)
parser.add_argument('--source-jpeg', type=Path, help='Capture an actual procedural JPEG through the production serializer')
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-drift-wire-'))
out.mkdir(parents=True, exist_ok=True)
live_path = root / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
drift_path = root / 'apps/ios/Rendprop/Render/DriftCheck.swift'
api_path = root / 'apps/ios/Rendprop/Networking/APIClient.swift'
digest_path = root / 'apps/ios/Rendprop/Upload/DirectUploader.swift'
fixture_path = root / 'apps/ios/tests/VideoDriftWireTests.swift'
consumed = [live_path, drift_path, api_path, digest_path, fixture_path, Path(__file__).resolve()]


def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed}


def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


receipt = {'passed': False, 'start_source_sha256': hashes(), 'commands': [], 'runs': [],
    'limitations': ['Actual aiVideoDrift, makeRequest, execute, URL helpers, digest helpers and decoder bodies execute unchanged.',
        'Foundation URLSession dispatch is captured by URLProtocol, including the actual serialized JSON body and headers.',
        'Account/token access and server replies are closed fixtures; no real Auth, Keychain, vendor, external network or simulator UI.',
        'This proves the real HTTP attempt values and framing/provenance payload, not provider output quality or full-phone completion.']}
if args.source_jpeg:
    args.source_jpeg = args.source_jpeg.resolve()
    data = args.source_jpeg.read_bytes()
    receipt['actual_source_jpeg'] = {'path': str(args.source_jpeg), 'bytes': len(data),
        'sha256': hashlib.sha256(data).hexdigest()}


def command(name, argv, timeout):
    started = time.monotonic()
    log_path = out / (name + '.log')
    event = {'name': name, 'argv': argv, 'timeout_seconds': timeout}
    receipt['commands'].append(event)
    try:
        with log_path.open('w') as log:
            result = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        event['exit_code'] = result.returncode
        return result.returncode, log_path.read_text()
    finally:
        event['elapsed_seconds'] = round(time.monotonic() - started, 3)
        event['log_path'] = str(log_path)
        event['log_sha256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()


try:
    live, drift, api, digest, fixture = [p.read_text() for p in [live_path, drift_path, api_path, digest_path, fixture_path]]
    methods = '\n'.join(block(live, anchor) for anchor in [
        '    private func url(', '    private enum Idempotency {',
        '    private func makeRequest(', '    private static func boundedIdempotencyKey(',
        '    private static func derivedIdempotencyKey(',
        '    @MainActor private func execute(', '    private struct ErrorEnvelope: Decodable {',
        '    static func serverError(', '    private func decode<T: Decodable>', '    func aiVideoDrift('])
    types = '\n'.join([block(api, 'enum APIError: Error, LocalizedError'),
        block(drift, 'struct DriftVerdict: Sendable, Equatable'), block(drift, 'struct DriftCheckRequest: Sendable')])
    digests = '\n'.join(block(digest, anchor) for anchor in ['    static func sha256Hex(_ string:', '    static func sha256Hex(_ data:'])
    actual = fixture.replace('// __ACTUAL_TYPES__', types).replace('// __ACTUAL_CLIENT_METHODS__', methods).replace('// __ACTUAL_DIGESTS__', digests)
    bound = 'max(0, min(3, request.attempt))'
    assert actual.count(bound) == 1
    provenance = '        if let p = request.provenanceID, !p.isEmpty { body["provenance_id"] = p }'
    assert actual.count(provenance) == 1
    variants = [('actual', actual, None),
        ('negative-old-attempt-one-clamp', actual.replace(bound, 'max(1, min(3, request.attempt))'), 'first attempt is serialized as 0'),
        ('negative-unbounded-attempt', actual.replace(bound, 'request.attempt'), 'negative attempt is serialized as 0'),
        ('negative-lost-provenance', actual.replace(provenance, '        // omitted provenance'), 'serialized QC forwards accepted provenance identity'),
        ('negative-legacy-default-zero', actual.replace('var attempt: Int = 1', 'var attempt: Int = 0'), 'legacy/default drift request remains conservative attempt one')]
    receipt['actual_method_sha256'] = hashlib.sha256(methods.encode()).hexdigest()
    for name, generated, expected_failure in variants:
        assert expected_failure is None or generated != actual
        swift, binary = out / (name + '.swift'), out / name
        swift.write_text(generated)
        code, output = command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)], 120)
        assert code == 0, name + ' compile failed: ' + output
        code, output = command(name, [str(binary)] + ([str(args.source_jpeg)] if args.source_jpeg else []), 30)
        passed = code == 0 if expected_failure is None else code != 0 and ('Precondition failed: ' + expected_failure) in output
        receipt['runs'].append({'name': name, 'exit_code': code, 'expected_result': passed,
            'expected_failure': expected_failure, 'source_sha256': hashlib.sha256(generated.encode()).hexdigest(), 'output': output[:2500]})
        assert passed, name + ': ' + output
        binary.unlink()
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    if args.source_jpeg:
        receipt['source_jpeg_binding_matches'] = hashlib.sha256(args.source_jpeg.read_bytes()).hexdigest() == receipt['actual_source_jpeg']['sha256']
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == 5 and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches'] and receipt.get('source_jpeg_binding_matches', True)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'QC wire source changed or a required control failed'
print(receipt['runs'][0]['output'].strip())
print('PASSED: four compiled wire negative controls failed at the expected assertions')
print(f'Evidence: {out}')
