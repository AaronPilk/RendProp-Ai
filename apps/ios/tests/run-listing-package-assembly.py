#!/usr/bin/env python3
"""Run actual package-assembly methods with closed UI and admission boundaries."""
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
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-package-assembly-'))
out.mkdir(parents=True, exist_ok=True)
source_path = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
export_path = root / 'apps/ios/Rendprop/Photos/PhotoExport.swift'
fixture_path = root / 'apps/ios/tests/ListingPackageAssemblyTests.swift'
consumed = [source_path, export_path, fixture_path, Path(__file__).resolve()]


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
           'limitations': ['Actual shareListingPackage and listingDetailsNote bodies execute unchanged.',
                          'Foundation file checks and note writes use isolated real files; the note temporary directory is injected.',
                          'Listing presentation values, enhanced-photo value fields and UI state/admission are closed doubles.',
                          'No vendor/network, customer files, Apple credentials, camera, Photos library or simulator use.',
                          'This assembly gate does not replace the actual UIKit JPEG/ZIP renderer and SwiftUI UI gates.']}


def command(name, argv, timeout):
    start = time.monotonic()
    event = {'name': name, 'argv': argv, 'deadline_seconds': timeout}
    receipt['commands'].append(event)
    log_path = out / (name + '.log')
    try:
        with log_path.open('w') as log:
            result = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        event['exit_code'] = result.returncode
        return result, log_path.read_text()
    finally:
        event['elapsed_seconds'] = round(time.monotonic() - start, 3)
        event['log_path'] = str(log_path)
        event['log_sha256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()


try:
    source, export, template = source_path.read_text(), export_path.read_text(), fixture_path.read_text()
    methods = '\n'.join(block(source, anchor) for anchor in [
        '    @MainActor private func shareListingPackage() {',
        '    private static func listingDetailsNote(for listing: Listing) throws -> URL {'])
    value_types = block(source, 'struct ListingMediaItem: Identifiable, Hashable, Sendable {')
    value_types += '\n' + block(export, 'struct PhotoExportSelection: Identifiable {')
    value_types += '\nenum PhotoExportRenderer {\n' + block(export, '    struct Extra: Identifiable, Hashable, Sendable {') + '\n}\n'
    actual = template.replace('// __ACTUAL_VALUE_TYPES__', value_types).replace('// __ACTUAL_ASSEMBLY_METHODS__', methods)
    # The allSatisfy closure is the first brace; extract the full outer guard
    # through its return and closing brace rather than stopping at the closure.
    start = actual.index('        guard items.allSatisfy(')
    end = actual.index('\n        let photos =', start)
    missing_guard = actual[start:end]
    write = 'try Data(lines.joined(separator: "\\n").utf8).write(to: url, options: .atomic)'
    assert actual.count(write) == 1
    variants = [
        ('actual', actual, None),
        ('negative-missing-source-guard', actual.replace(missing_guard, '        // missing-source refusal omitted'),
         'a missing cached video prevents package presentation'),
        ('negative-swallowed-details-error', actual.replace(write, 'try? Data(lines.joined(separator: "\\n").utf8).write(to: url, options: .atomic)'),
         'details write failure prevents package presentation'),
        ('negative-admission-guard', actual.replace('guard !items.isEmpty, admission() else { return }', 'guard !items.isEmpty else { return }'),
         'refused admission prevents package presentation'),
        ('negative-original-mutated', actual.replace('        let items = mediaItems\n',
         '        let items = mediaItems\n        if let item = items.first { try? Data("mutated".utf8).write(to: item.url, options: .atomic) }\n'),
         'package assembly leaves all original media bytes unchanged'),
    ]
    receipt['actual_method_sha256'] = hashlib.sha256(methods.encode()).hexdigest()
    receipt['actual_value_types_sha256'] = hashlib.sha256(value_types.encode()).hexdigest()
    for name, generated, failure in variants:
        assert failure is None or generated != actual, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(generated)
        built, diagnostics = command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], 120)
        assert built.returncode == 0, name + ' compile failed: ' + diagnostics
        ran, output = command(name, [str(binary)], 30)
        expected = ran.returncode == 0 if failure is None else ran.returncode != 0 and ('Precondition failed: ' + failure) in output
        receipt['runs'].append({'name': name, 'exit_code': ran.returncode, 'expected_result': expected,
                                'expected_failure': failure, 'source_sha256': hashlib.sha256(generated.encode()).hexdigest(),
                                'output': output[:2500]})
        assert expected, name + ': ' + output
        binary.unlink()
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == 5 and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Assembly source changed during verification or a required control failed'
print(receipt['runs'][0]['output'].strip())
print('PASSED: four compiled negative controls failed at their expected invariant')
print(f'Evidence: {out}')
