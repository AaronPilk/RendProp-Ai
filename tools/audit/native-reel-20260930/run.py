#!/usr/bin/env python3
"""Encoded macOS AVFoundation checks using the production composition core.
UIKit overlays are omitted (not tested here); no camera, simulator, or provider.
"""
import array, hashlib, json, math, pathlib, shutil, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(tempfile.mkdtemp(prefix="rendprop-native-reel-"))
def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, **kw)
source_path = ROOT / 'apps/ios/Rendprop/Render/ReelComposer.swift'
source = source_path.read_text()
a = source.index('    // MARK: - Overlay')
b = source.index('    // MARK: - Geometry', a)
# Overlay uses UIKit. Keep every prepare/layout/audio/export/geometry method unchanged.
core = source[:a] + '''    private static func buildOverlay(options: Options, captions: [ShotCaption],
        renderSize: CGSize, hasAudio: Bool) -> CALayer? { nil }
''' + source[b:]
core = core.replace('import UIKit\n', '')
(OUT / 'Composer.swift').write_text(core)
(OUT / 'Harness.swift').write_text('''import Foundation
import AVFoundation
struct CaptionStyle: Sendable { static let off = CaptionStyle() }
struct Voiceover: Sendable { let audioURL: URL }
@main struct Check {
 static func main() async throws {
  let d = URL(fileURLWithPath: CommandLine.arguments[1])
  let a = d.appendingPathComponent("a.mp4"), b = d.appendingPathComponent("b.mp4")
  let size = CGSize(width: 320, height: 180)
  let strict = ReelComposer.Options(requireAllShots: true)
  try await ReelComposer.compose(shots: [.init(url: a, seconds: 1, keepOriginalAudio: true),
     .init(url: b, keepOriginalAudio: true)], renderSize: size, options: strict,
     output: d.appendingPathComponent("cut.mp4"))
  try await ReelComposer.compose(shots: [.init(url: b, keepOriginalAudio: true),
     .init(url: a, keepOriginalAudio: true)], renderSize: size,
     options: .init(transition: .dissolve, requireAllShots: true),
     output: d.appendingPathComponent("blend.mp4"))
  try await ReelComposer.compose(shots: [.init(url: a, seconds: 1, speed: 2, keepOriginalAudio: true)],
     renderSize: size, options: strict, output: d.appendingPathComponent("retimed.mp4"))
  try await ReelComposer.compose(shots: [.init(url: a)], renderSize: size, options: strict,
     output: d.appendingPathComponent("legacy-silent.mp4"))
  do {
   try await ReelComposer.compose(shots: [.init(url: a), .init(url: d.appendingPathComponent("missing.mp4"))],
      renderSize: size, options: strict, output: d.appendingPathComponent("must-not-exist.mp4"))
   fatalError("Missing selected footage was silently dropped")
  } catch { print("missing-source-rejected") }
  do {
   try await ReelComposer.compose(shots: [.init(url: a)], renderSize: size,
      options: .init(voiceover: .init(audioURL: d.appendingPathComponent("missing.m4a")), requireAllShots: true),
      output: d.appendingPathComponent("must-not-silence.mp4"))
   fatalError("Missing narration was silently dropped")
  } catch { print("missing-narration-rejected") }
 }
}
''')
for name, color, frequency, duration in [('a', 'red', 440, 2), ('b', 'blue', 880, 3)]:
    run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'color={color}:s=320x180:r=30:d={duration}',
         '-f', 'lavfi', '-i', f'sine=frequency={frequency}:sample_rate=48000:duration={duration}',
         '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', str(OUT/f'{name}.mp4')])
try:
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(OUT/'Composer.swift'),
         str(OUT/'Harness.swift'), '-o', str(OUT/'check')])
    result = run([str(OUT/'check'), str(OUT)], timeout=120)
except subprocess.CalledProcessError as exc:
    print(exc.stderr.decode()); raise
assert b'missing-source-rejected' in result.stdout
assert b'missing-narration-rejected' in result.stdout
assert not (OUT/'must-not-exist.mp4').exists()
assert not (OUT/'must-not-silence.mp4').exists()
checks = ['missing-source-rejected-without-output', 'missing-narration-rejected-without-output']
def probe(name):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(OUT/name)]).stdout)
def pcm(name, start, duration=.4):
    raw = run(['ffmpeg', '-v', 'error', '-ss', str(start), '-i', str(OUT/name), '-t', str(duration),
               '-vn', '-ac', '1', '-ar', '8000', '-f', 'f32le', 'pipe:1']).stdout
    values = array.array('f'); values.frombytes(raw)
    return values

def energy(samples, hz):
    return abs(sum(complex(math.cos(2*math.pi*hz*i/8000), -math.sin(2*math.pi*hz*i/8000))*x
                   for i,x in enumerate(samples))) / len(samples)
def tone(name, start, wanted, unwanted):
    samples = pcm(name, start)
    assert energy(samples, wanted) > energy(samples, unwanted) * 8, (name, start, wanted)
    assert math.sqrt(sum(v*v for v in samples)/len(samples)) > .02
    checks.append(f'{name}-{start}s-{wanted}Hz')
for name, expected in [('cut.mp4',4), ('blend.mp4',4.72), ('retimed.mp4',1), ('legacy-silent.mp4',2)]:
    info = probe(name)
    assert abs(float(info['format']['duration'])-expected) < .09, (name, info['format']['duration'])
    checks.append(f'{name}-duration')
    audio = [s for s in info['streams'] if s['codec_type']=='audio']
    assert bool(audio) == (name != 'legacy-silent.mp4')
    checks.append(f'{name}-audio-presence')
tone('cut.mp4', .2, 440, 880)
tone('cut.mp4', 1.4, 880, 440)
tone('blend.mp4', .4, 880, 440)
tone('blend.mp4', 3.2, 440, 880)
assert math.sqrt(sum(v*v for v in pcm('retimed.mp4', .2))/len(pcm('retimed.mp4', .2))) > .02
checks.append('retimed-audio-not-silent')
receipt = {'production_source_sha256': hashlib.sha256(source.encode()).hexdigest(),
           'scope': 'macOS encoded production composition core; UIKit overlays and iPhone capture excluded',
           'checks': checks, 'passed': len(checks), 'output': str(OUT)}
(OUT/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(json.dumps(receipt, indent=2))
