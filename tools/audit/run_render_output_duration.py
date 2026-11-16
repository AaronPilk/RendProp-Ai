#!/usr/bin/env python3
"""Fault-test the native tour export's final duration guard with synthetic MP4s.

No camera, customer media, app container, network, provider or production write.
"""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix='rendprop-render-concurrency-duration-'))
    # The production dependency shim confines actual rendered files to /tmp;
    # keep logs/receipt under TMPDIR so CI uploads the evidence automatically.
    render_root = Path(tempfile.mkdtemp(prefix='rendprop-render-concurrency-duration-renders-', dir='/tmp'))
    print(f'EVIDENCE: {out}', flush=True)
    engine = root / 'apps/ios/Rendprop/Render/RenderEngine.swift'
    test = root / 'tests/phase1/RenderOutputDurationTests.swift'
    dependencies = [root / p for p in [
        'apps/ios/Rendprop/Models/CaptureAsset.swift',
        'apps/ios/Rendprop/Models/RoomTag.swift',
        'tests/phase1/RenderEngineDependencies.swift',
    ]]
    source = engine.read_text()
    # The private check must protect the production temp -> final handoff.
    validation_call = 'try await verifyCompletedOutput(at: tempURL, expectedDuration: outDuration.seconds)'
    final_move = 'try replaceItem(at: outURL, with: tempURL)'
    assert source.count(validation_call) == 1 and source.count(final_move) == 1
    assert source.index(validation_call) < source.index(final_move)
    condition = 'observedDuration + allowedShortfall >= expectedDuration'
    assert source.count(condition) == 1
    assert platform.system() == 'Darwin'
    ffmpeg = shutil.which('ffmpeg')
    assert ffmpeg, 'ffmpeg required for synthetic video fixtures'
    receipt = {'accepted': False, 'sourceCommit': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'sourceSHA256': hashlib.sha256(engine.read_bytes()).hexdigest(), 'commands': []}

    def run(name, command, expected=0, extra_env=None):
        result = subprocess.run(list(map(str, command)), cwd=root, text=True,
                                env={**os.environ, **(extra_env or {})},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        log = out / f'{name}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': name, 'exit': result.returncode,
                                    'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        if expected == 'failure':
            assert result.returncode != 0, f'{name} unexpectedly passed; {log}'
        else:
            assert result.returncode == expected, f'{name}: exit {result.returncode}, expected {expected}; {log}'
        print(f'{name}: exit={result.returncode}', flush=True)
        return result.stdout

    def make(name, frames):
        movie = out / f'{name}.mp4'
        run(f'make-{name}', [ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'testsrc2=size=64x48:rate=30', '-frames:v', frames,
            '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', movie])
        return movie

    try:
        full = make('full', 30)
        short = make('one-frame', 1)
        tiny = make('valid-tiny', 6)
        invalid = out / 'invalid.mp4'
        invalid.write_bytes(b'not an mp4')
        combined = out / 'RenderEngine-with-duration-tests.swift'
        combined.write_text(source + '\n' + test.read_text())
        native = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-warnings-as-errors',
                  '-target', f'{platform.machine()}-apple-macosx13.0',
                  '-module-cache-path', out / 'native-module-cache']
        executable = out / 'duration-test'
        run('compile-native', [*native, combined, *dependencies, '-o', executable])
        args = [full, short, tiny, invalid]
        positive = run('duration-fault-test', [executable, *args])
        assert 'PASS: full and valid tiny MP4 accepted; one-frame and malformed MP4 rejected' in positive

        # Normal 2/3/8-second exports cover both the 1.5x short-take and
        # 2x long-take branches. The completeness check must admit all three.
        for seconds, frames in [(2, 90), (3, 135), (8, 480)]:
            clip = make(f'source-for-{seconds}s-export', frames)
            destination = render_root / f'render-{seconds}s'
            destination.mkdir()
            render = run(f'actual-render-{seconds}s', [executable, '--render', clip, seconds],
                         extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)})
            assert f'PASS: actual {seconds}.0s RenderEngine export completed' in render

        # Remove only the truncation threshold from a private source copy.
        # The one-frame fixture must expose this mutation, not pass on an
        # unrelated malformed-file or compiler failure.
        mutant = out / 'RenderEngine-no-duration-threshold.swift'
        mutant.write_text(source.replace(condition, 'observedDuration + allowedShortfall >= 0')
                          + '\n' + test.read_text())
        mutant_executable = out / 'duration-mutant'
        run('compile-mutant', [*native, mutant, *dependencies, '-o', mutant_executable])
        rejected = run('reject-duration-mutant', [mutant_executable, *args], expected='failure')
        assert 'FAIL: one-frame truncated MP4 was accepted' in rejected
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'], f'Native duration fault test failed: {out}'


if __name__ == '__main__':
    main()
