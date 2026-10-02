#!/usr/bin/env python3
"""HD published masters: actual native and worker exports of synthetic media.

No camera, customer media, credentials, provider calls or production writes.
Preserves the standard tour's retiming, silent audio and every-frame keyframes.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import platform
import random
import shutil
import struct
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix='rendprop-render-concurrency-hd-'))
    print(f'EVIDENCE: {out}', flush=True)
    engine = root / 'apps/ios/Rendprop/Render/RenderEngine.swift'
    sources = [engine, root / 'tests/phase1/RenderQualityRuntimeTests.swift',
               root / 'apps/ios/Rendprop/Models/CaptureAsset.swift',
               root / 'apps/ios/Rendprop/Models/RoomTag.swift',
               root / 'tests/phase1/RenderQualityRuntimeDependencies.swift',
               root / 'services/worker/settings.py', root / 'services/worker/ffmpeg_render.py', Path(__file__)]
    receipt = {'accepted': False, 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
               'sourceHashes': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               'commands': [], 'outputs': [], 'cameraUsed': False, 'customerWrites': False, 'paidGeneration': False}
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    assert ffmpeg and ffprobe, 'Install ffmpeg and ffprobe before the HD gate'
    assert platform.system() == 'Darwin', 'This gate compiles the actual Apple AVFoundation pipeline'
    architecture = platform.machine()
    assert architecture in ['arm64', 'x86_64'], f'Unsupported macOS architecture: {architecture}'
    env = {**os.environ, 'LC_ALL': 'C', 'RENDER_QUALITY_FIXTURE_ROOT': str(out)}

    def run(label, args, *, extra_env=None, expected=0):
        result = subprocess.run(list(map(str, args)), cwd=root, env={**env, **(extra_env or {})}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=150)
        log = out / f'{label}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': label, 'exit': result.returncode, 'log': str(log),
                                    'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        if expected == 'failure':
            assert result.returncode != 0, f'{label} unexpectedly passed'
        else:
            assert result.returncode == expected, f'{label}: exit{result.returncode}; {log}'
        print(f'{label}: exit={result.returncode}', flush=True)
        return result.stdout

    def verify(path, dimensions, label, expected_frames, fast_start=True):
        probe = json.loads(run(label + '-probe', [ffprobe, '-v', 'error', '-show_streams', '-show_frames',
            '-show_entries', 'stream=codec_type,width,height,r_frame_rate,color_space,color_transfer,color_primaries,bit_rate:frame=key_frame,pts_time',
            '-of', 'json', path]))
        video, = probe['streams']
        assert video['codec_type'] == 'video', 'Standard tour must stay silent'
        assert (video['width'], video['height']) == dimensions
        assert video['r_frame_rate'] == '60/1'
        assert all(video.get(k) == 'bt709' for k in ['color_space', 'color_transfer', 'color_primaries'])
        assert len(probe['frames']) == expected_frames and all(f['key_frame'] == 1 for f in probe['frames']), 'Expected complete independently decodable frames'
        data = path.read_bytes()
        atoms = []
        pos = 0
        while pos + 8 <= len(data):
            n, kind = struct.unpack('>I4s', data[pos:pos + 8])
            if n == 1:
                n = struct.unpack('>Q', data[pos + 8:pos + 16])[0]
            if n == 0:
                n = len(data) - pos
            assert n >= 8 and pos + n <= len(data), 'Invalid MP4 atom'
            atoms.append(kind.decode('ascii'))
            pos += n
        assert (atoms.index('moov') < atoms.index('mdat')) == fast_start, 'Unexpected MP4 metadata order'
        timing = [f['pts_time'] for f in probe['frames']]
        receipt['outputs'].append({'label': label, 'path': str(path), 'stream': video, 'frames': expected_frames,
            'allIntra': True, 'fastStart': fast_start, 'framePTS': timing,
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        return timing

    try:
        dependencies = sources[2:5]
        swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-warnings-as-errors']
        sdk = run('simulator-sdk', ['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
        run('ios-sdk-typecheck', [*swift, '-typecheck', '-sdk', sdk, '-target', f'{architecture}-apple-ios16.0-simulator',
            '-module-cache-path', out / 'ios-module-cache', engine, *dependencies])
        executable = out / 'render-hd'
        native = [*swift, '-target', f'{architecture}-apple-macosx13.0', '-module-cache-path', out / 'native-module-cache']
        run('compile-native', [*native, engine, *dependencies, sources[1], '-o', executable])
        fixtures = [('hd', 1920, 1080, 1920, 1080), ('4k', 3840, 2160, 1920, 1080),
                    ('portrait', 1080, 1920, 1080, 1920), ('small', 640, 480, 640, 480)]
        for name, width, height, wanted_width, wanted_height in fixtures:
            clip = out / f'{name}-input.mp4'
            # Fine monochrome detail is deliberately harder to retain than a
            # constant color. Add source audio to prove it stays a silent tour.
            run('make-' + name, [ffmpeg, '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', f"color=gray:size={width}x{height}:rate=30:duration=1.5,format=yuv420p,geq=lum='128+60*sin(2*PI*X/4)':cb=128:cr=128",
                '-f', 'lavfi', '-i', 'sine=frequency=1000:duration=1.5', '-c:v', 'libx264', '-crf', '10',
                '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                '-c:a', 'aac', '-shortest', clip])
            destination = out / ('native-' + name)
            destination.mkdir()
            output_receipt = destination / 'output.json'
            run('native-' + name, [executable, clip, output_receipt, wanted_width, wanted_height],
                extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)})
            native_output = Path(json.loads(output_receipt.read_text())['path'])
            # AVFoundation's existing identity-composition path retimes the45
            # input frames onto the1/60 grid without synthesizing15 extra
            # frames. Below, compare actual PTS to the prechange policy; never
            # confuse nominal60fps with measured unique frame count.
            verify(native_output, (wanted_width, wanted_height), 'native-' + name, 45)

        # Distinct, fixed spatial features make the stationary clip measurable;
        # a repeated stripe or blank wall cannot prove zero corrected motion.
        # The jitter clip uses these exact same pixels with known translations.
        still = out / 'motion-features.ppm'
        rng = random.Random(7319)
        width, height = 704, 424
        blocks = {(x, y): tuple(rng.randrange(20, 225) for _ in range(3))
                  for y in range(0, height, 16) for x in range(0, width, 16)}
        pixels = bytearray()
        for y in range(height):
            for x in range(width):
                pixels.extend(blocks[(x // 16 * 16, y // 16 * 16)])
        still.write_bytes(f'P6\n{width} {height}\n255\n'.encode() + pixels)
        motion_fixtures = [('stationary', 'crop=640:360:32:32', 'steady'),
                           ('jitter', "crop=640:360:x='32+10*sin(n*PI/3)':y='32+8*cos(n*PI/5)'", 'applied'),
                           ('featureless', None, 'unavailable')]
        receipt['syntheticMotion'] = []
        for name, crop, expected_motion in motion_fixtures:
            clip = out / f'motion-{name}-input.mp4'
            source_args = (['-loop', '1', '-framerate', '30', '-i', still, '-vf', crop]
                           if crop else ['-f', 'lavfi', '-i', 'color=gray:size=640x360:rate=30'])
            run('make-motion-' + name, [ffmpeg, '-hide_banner', '-loglevel', 'error',
                *source_args, '-t', '1.5', '-c:v', 'libx264', '-crf', '10', '-pix_fmt', 'yuv420p',
                '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', clip])
            destination = out / ('motion-' + name)
            destination.mkdir()
            output_receipt = destination / 'output.json'
            run('motion-' + name, [executable, clip, output_receipt, 640, 360, expected_motion],
                extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)})
            diagnostic = json.loads(output_receipt.read_text())
            verify(Path(diagnostic['path']), (640, 360), 'motion-' + name,
                   45 if expected_motion == 'unavailable' else 60)
            receipt['syntheticMotion'].append({'fixture': name, 'expected': expected_motion,
                'motionSmoothing': diagnostic['motionSmoothing'], 'stabilized': diagnostic['stabilized'],
                'outputReceipt': str(output_receipt), 'outputReceiptSHA256': hashlib.sha256(output_receipt.read_bytes()).hexdigest()})

        # Restore only the former crop-based success check in a private copy.
        # The stationary clip still gets the safety crop; claiming correction
        # was applied must fail the exact production-output diagnostic check.
        crop_mutant = out / 'crop-positive.swift'
        original = engine.read_text()
        motion_needle = 'stabilized = corrections.contains { abs($0.x) > 0.01 || abs($0.y) > 0.01 }'
        assert original.count(motion_needle) == 1
        crop_mutant.write_text(original.replace(motion_needle, 'stabilized = cropZoom > 1.0001'))
        crop_mutant_bin = out / 'crop-positive'
        run('compile-crop-positive', [*native, crop_mutant, *dependencies, sources[1], '-o', crop_mutant_bin])
        destination = out / 'reject-crop-positive'
        destination.mkdir()
        rejected_crop = run('reject-crop-positive', [crop_mutant_bin, out / 'motion-stationary-input.mp4',
            destination / 'output.json', 640, 360, 'steady'],
            extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)}, expected='failure')
        assert 'Motion smoothing status mismatch: applied, expected steady' in rejected_crop, 'Crop mutant failed for an unrelated reason'
        receipt['motionNegativeControl'] = 'Former crop-only positive rejected by stationary actual RenderEngine diagnostic'

        # Revert just the dimensions ceiling in a copied source; actual encoded
        # media must fail the HD assertion. This protects against a test which
        # merely repeats a constant without exercising the production pipeline.
        mutant = out / 'legacy-ceiling.swift'
        source = engine.read_text()
        needle = 'private static let encodeLongEdge: CGFloat = 1920'
        assert source.count(needle) == 1
        mutant.write_text(source.replace(needle, 'private static let encodeLongEdge: CGFloat = 1280')
            .replace('AVVideoAverageBitRateKey: 24_000_000', 'AVVideoAverageBitRateKey: 9_000_000')
            .replace('writer.shouldOptimizeForNetworkUse = true', '// Prechange: metadata follows video bytes.'))
        mutant_bin = out / 'legacy-ceiling'
        run('compile-legacy-ceiling', [*native, mutant, *dependencies, sources[1], '-o', mutant_bin])
        destination = out / 'reject-legacy-ceiling'
        destination.mkdir()
        rejected = run('reject-legacy-ceiling', [mutant_bin, out / 'hd-input.mp4', destination / 'output.json', 1920, 1080],
            extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)}, expected='failure')
        assert 'HD dimensions missing' in rejected, 'Negative control failed for an unrelated reason'
        receipt['negativeControl'] = 'Actual legacy1280 output rejected by HD dimensions assertion'
        legacy_receipt = destination / 'legacy-output.json'
        run('legacy-timing-baseline', [mutant_bin, out / 'hd-input.mp4', legacy_receipt, 1280, 720],
            extra_env={'RENDER_FIXTURE_DIRECTORY': str(destination)})
        legacy_output = Path(json.loads(legacy_receipt.read_text())['path'])
        old_pts = verify(legacy_output, (1280, 720), 'legacy-timing-baseline', 45, False)
        hd = next(row for row in receipt['outputs'] if row['label'] == 'native-hd')
        assert old_pts == hd['framePTS'], 'HD policy must preserve actual frame timestamps'

        # Compare actual decoded detail to the same generated reference at HD.
        # This also rejects passing a720p frame enlarged into a1920 container.
        def luma(path):
            return subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(path),
                '-vf', 'scale=1920:1080:flags=bicubic', '-frames:v', '1', '-pix_fmt', 'gray', '-f', 'rawvideo', '-'], timeout=30)
        reference = luma(out / 'hd-input.mp4')
        fresh = luma(Path(hd['path']))
        previous = luma(legacy_output)
        def psnr(pixels):
            assert len(pixels) == len(reference) == 1920 * 1080
            mse = sum((a - b) ** 2 for a, b in zip(reference, pixels)) / len(reference)
            return 10 * math.log10(255 ** 2 / max(mse, 1e-12))
        quality = {'metric': 'lumaPSNR', 'generatedReference': 'HD fine-detail sine pattern',
                   'newHD': psnr(fresh), 'legacy720UpToHD': psnr(previous)}
        assert quality['newHD'] > quality['legacy720UpToHD'] + 3, 'Actual HD detail must improve, not just dimensions'
        receipt['syntheticDetail'] = quality

        # Run the server's actual render() boundary with the same generated
        # files. Clear only explicit encode environment overrides for this test
        # so the committed defaults (not a duplicated test policy) are proven.
        # Load the actual committed worker files from a clean temporary folder
        # with no .env; preserve their exact source bytes. This avoids loading
        # ignored local credentials/config or masking default values with test
        # constants. Only ffmpeg/ffprobe locations are overridden.
        clean_worker = out / 'worker-source'
        clean_worker.mkdir()
        for name in ['settings.py', 'ffmpeg_render.py']:
            shutil.copyfile(root / 'services/worker' / name, clean_worker / name)
        isolated_worker_env = {'PATH': os.environ.get('PATH', ''), 'LC_ALL': 'C',
                              'FFMPEG_BIN': ffmpeg, 'FFPROBE_BIN': ffprobe}
        original_env = dict(os.environ)
        os.environ.clear()
        os.environ.update(isolated_worker_env)
        sys.path.insert(0, str(clean_worker))
        import ffmpeg_render
        os.environ.clear()
        os.environ.update(original_env)
        assert ffmpeg_render.SETTINGS.encode_long_edge == 1920
        assert ffmpeg_render.SETTINGS.encode_fps == 60
        assert ffmpeg_render.SETTINGS.encode_bitrate == '24M'
        for name, _, _, wanted_width, wanted_height in fixtures:
            destination = out / ('worker-' + name)
            output, poster, duration, speed = ffmpeg_render.render(str(out / f'{name}-input.mp4'), False, workdir=str(destination))
            assert abs(duration - 1.0) < .04 and speed == 1.5 and Path(poster).is_file()
            verify(Path(output), (wanted_width, wanted_height), 'worker-' + name, 60)
            if name == 'hd':
                legacy_tags = destination / 'before-explicit-color-tags.mp4'
                command = ffmpeg_render._encode_cmd(str(out / 'hd-input.mp4'), str(legacy_tags), 1.5)
                command = [part.replace(':colorprim=bt709:transfer=bt709:colormatrix=bt709', '') for part in command]
                run('worker-before-explicit-color-tags', command)
                # Compare decoded Y pixels, independent of container/VUI tags:
                # the tag fix must not change the actual encoded image.
                def decoded_y(path):
                    return subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(path), '-vf', 'extractplanes=y',
                        '-frames:v', '1', '-f', 'rawvideo', '-'], timeout=30)
                old_y, new_y = decoded_y(legacy_tags), decoded_y(output)
                assert old_y == new_y and len(new_y) == 1920 * 1080
                receipt['workerColorMetadata'] = {'primaries': 'bt709', 'transfer': 'bt709', 'matrix': 'bt709',
                    'decodedLumaUnchanged': True, 'decodedLumaSHA256': hashlib.sha256(new_y).hexdigest()}
        assert all(hashlib.sha256(p.read_bytes()).hexdigest() == receipt['sourceHashes'][str(p.relative_to(root))] for p in sources)
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'], f'HD master gate failed: {out}'


if __name__ == '__main__':
    main()
