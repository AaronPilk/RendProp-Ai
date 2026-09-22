#!/usr/bin/env python3
"""Focused actual-SDK compile and tiny real encode checks; no Xcode app build.

Only synthetic media under a fresh /tmp directory. No camera, credentials,
network/provider, app container, Apple, or production operation.
"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import tempfile

BASE = '2750953'


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix='rendprop-render-concurrency-', dir='/tmp'))
    env = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'LC_ALL': 'C'}
    engine = root / 'apps/ios/Rendprop/Render/RenderEngine.swift'
    extension = root / 'tests/phase1/RenderEncodeSessionTests.swift'
    runtime = root / 'tests/phase1/RenderEngineRuntimeTests.swift'
    dependencies = [root / p for p in ['apps/ios/Rendprop/Models/CaptureAsset.swift',
        'apps/ios/Rendprop/Models/RoomTag.swift', 'tests/phase1/RenderEngineDependencies.swift']]
    importer = root / 'apps/ios/Rendprop/Import/MediaImporter.swift'
    paths = [engine, extension, runtime, *dependencies, importer, Path(__file__)]
    receipt = {'accepted': False, 'sourceHashes': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
               'commands': [], 'runtimeAssertionsPerRun': 18, 'mediaChecks': []}
    receipt['sourceCommit'] = subprocess.check_output(['/usr/bin/git', 'rev-parse', 'HEAD'], cwd=root, env=env, text=True).strip()
    receipt['sourceClean'] = not subprocess.check_output(['/usr/bin/git', 'status', '--porcelain'], cwd=root, env=env, text=True).strip()
    print(f'EVIDENCE: {out}', flush=True)

    def run(label, args, expected=0, extra_env=None):
        result = subprocess.run(list(map(str, args)), cwd=root, env={**env, **(extra_env or {})}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        log = out / f'{label}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': label, 'command': list(map(str, args)), 'exit': result.returncode,
            'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        assert result.returncode == expected, f'{label}: exit{result.returncode} != {expected}; {log}'
        print(f'{label}: exit={result.returncode}', flush=True)
        return result.stdout

    try:
        source = engine.read_text()
        for symbol in ['private final class EncodeSession: @unchecked Sendable',
                       'dispatchPrecondition(condition: .onQueue(queue))', 'continuation = nil',
                       '[weak self] in self?.pump()', 'self.queue.async { self.finish(.failure(RenderError.cancelled)) }']:
            assert symbol in source, f'Actual source patch missing: {symbol}'
        assert '@preconcurrency import' not in source
        for name, number in [('maxDurationSeconds', '600'), ('minDurationSeconds', '0.2')]:
            assert f'static let {name}: Double = {number}\n' in importer.read_text(), 'Fixture import boundary drifted'
        assert shutil.disk_usage('/tmp').free >= 512 * 1024**2, 'Need512MiB free; no cleanup performed'
        version = run('swift-version', ['/usr/bin/xcrun', 'swiftc', '--version'])
        assert 'Swift version' in version
        sdk = run('simulator-sdk', ['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
        assert Path(sdk).is_dir()
        # Existing caches keep this bounded; no full DerivedData regeneration.
        ios_cache = Path('/tmp/rendprop-spatial-integration.sLQDuM/DerivedData/ModuleCache.noindex')
        native_cache = Path('/Users/pilksclaes/Library/Developer/Xcode/DerivedData/ModuleCache.noindex')
        assert ios_cache.is_dir() and native_cache.is_dir(), 'Expected existing module caches are unavailable'
        swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-warnings-as-errors']
        ios = [*swift, '-typecheck', '-sdk', sdk, '-target', 'arm64-apple-ios16.0-simulator', '-module-cache-path', ios_cache]
        baseline = out / 'RenderEngine-baseline.swift'
        saved = subprocess.run(['/usr/bin/git', 'show', f'{BASE}:apps/ios/Rendprop/Render/RenderEngine.swift'], cwd=root,
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        assert saved.returncode == 0
        baseline.write_bytes(saved.stdout)
        before = run('before-ios-typecheck', [*ios, baseline, *dependencies], 1)
        captures = re.findall(r"^/[^\n]+\.swift:\d+:\d+: error: capture of '([^']+)' with non-Sendable type", before, re.MULTILINE)
        assert sorted(captures) == ['reader', 'readerOutput', 'writer', 'writerInput'], 'Baseline failed for a different reason'
        assert not run('after-ios-typecheck', [*ios, engine, *dependencies]).strip(), 'Unexpected compiler diagnostics'

        # Compiling the complete source with a same-file test extension preserves
        # private production visibility. Only the stalled WriterInput is fake.
        combined = out / 'RenderEngine-with-tests.swift'
        combined.write_text(source + '\n' + extension.read_text())
        native = [*swift, '-target', 'arm64-apple-macosx13.0', '-module-cache-path', native_cache]
        executable = out / 'render-tests'
        run('compile-runtime', [*native, combined, *dependencies, runtime, '-o', executable])
        clip = out / 'input.mp4'
        run('make-synthetic-clip', ['/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
            'testsrc2=size=64x48:rate=30:duration=1.5', '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', clip])

        def runtime_run(label, binary, expected=0):
            destination = out / label
            destination.mkdir()
            return run(label, [binary, clip], expected, {'RENDER_FIXTURE_DIRECTORY': str(destination)})

        for label in ['after-runtime', 'repeated-runtime']:
            result = runtime_run(label, executable)
            assert 'PASS: 15 actual RenderEngine assertions; 3 completed renders; 1 cancelled render; 0 skips' in result
            assert 'PASS: 3 stalled-session assertions; cancellation wakes without another ready callback; 0 skips' in result
            tours = sorted((out / label / 'renders').glob('tour-*.mp4'))
            assert len(tours) == 3, 'Exactly three real completed exports required'
            for n, tour in enumerate(tours):
                probe = json.loads(run(f'{label}-probe-{n}', ['/opt/homebrew/bin/ffprobe', '-v', 'error', '-show_streams', '-show_frames',
                    '-select_streams', 'v:0', '-show_entries', 'stream=width,height,r_frame_rate,color_space,color_transfer,color_primaries:frame=key_frame',
                    '-of', 'json', tour]))
                stream, = probe['streams']
                expected_stream = {'width': 64, 'height': 48, 'r_frame_rate': '60/1', 'color_space': 'bt709',
                                   'color_transfer': 'bt709', 'color_primaries': 'bt709'}
                assert {key: stream.get(key) for key in expected_stream} == expected_stream, stream
                assert len(probe['frames']) == 60 and all(frame['key_frame'] == 1 for frame in probe['frames'])
                receipt['mediaChecks'].append({'path': str(tour), 'frames': 60, 'allIntra': True, 'stream': expected_stream,
                                              'sha256': hashlib.sha256(tour.read_bytes()).hexdigest()})

        # Remove only the proactive cancellation dispatch in a copied source.
        # The actual stalled callback has already returned, so polling the flag
        # alone cannot let this mutant pass accidentally.
        needle = 'self.queue.async { self.finish(.failure(RenderError.cancelled)) }'
        assert source.count(needle) == 1
        mutant = out / 'RenderEngine-mutant.swift'
        mutant.write_text(source.replace(needle, '// deliberate test mutant: no cancellation wakeup') + '\n' + extension.read_text())
        mutant_bin = out / 'render-mutant'
        run('compile-mutant', [*native, mutant, *dependencies, runtime, '-o', mutant_bin])
        rejected = runtime_run('reject-stalled-cancel-mutant', mutant_bin, 1)
        assert 'FAIL: stalled encode cancellation did not resume' in rejected, 'Wrong-reason negative control'
        assert all(hashlib.sha256(p.read_bytes()).hexdigest() == receipt['sourceHashes'][str(p.relative_to(root))] for p in paths)
        assert subprocess.check_output(['/usr/bin/git', 'rev-parse', 'HEAD'], cwd=root, env=env, text=True).strip() == receipt['sourceCommit']
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'], f'Render gate failed: {out}'


if __name__ == '__main__':
    main()
