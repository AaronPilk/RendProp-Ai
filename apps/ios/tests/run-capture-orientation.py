#!/usr/bin/env python3
"""Actual capture guidance/framing/music receipt policies, closed UI/audio."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-capture-guide-'))).resolve(); out.mkdir(parents=True, exist_ok=True)
names = ['apps/ios/Rendprop/Capture/CaptureOrientationPolicy.swift', 'apps/ios/Rendprop/Render/VideoMusicContract.swift', 'apps/ios/Rendprop/Render/VideoAspectChoice.swift', 'apps/ios/Rendprop/Capture/VideoPhotoFramingReview.swift']
paths = [ROOT / x for x in names]
fixture = ROOT / 'apps/ios/tests/CaptureOrientationTests.swift'
bindings = paths + [fixture, Path(__file__), *[ROOT / x for x in ['apps/ios/Rendprop/Capture/CaptureOrientationGuide.swift',
    'apps/ios/Rendprop/Capture/VideoFramingPreviewSheet.swift','apps/ios/Rendprop/Capture/VideoFramingReviewSheet.swift','apps/ios/Rendprop/Capture/GuidedPhotoCamera.swift',
    'apps/ios/Rendprop/Render/VideoMusicCatalog.swift','apps/ios/Rendprop/Render/VideoMusicPicker.swift',
    'apps/ios/Rendprop/Screens/FlythroughDetailView.swift','apps/ios/Rendprop/Screens/NewListingView.swift']]]
assets = list((ROOT/'apps/ios/Rendprop/Resources/Music').glob('*'))
hashes = lambda: {str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in bindings+assets}
before = hashes(); source = '\n'.join(x.read_text() for x in paths)
catalog = json.loads((ROOT/'apps/ios/Rendprop/Resources/Music/property-video-music-catalog.json').read_text())
for track in catalog:
    actual = ROOT/'apps/ios/Rendprop/Resources'/track['assetRelativePath']
    assert hashlib.sha256(actual.read_bytes()).hexdigest() == track['assetSHA256']
guide = (ROOT/'apps/ios/Rendprop/Capture/CaptureOrientationGuide.swift').read_text()
assert '@Environment(\\.accessibilityReduceMotion)' in guide and '.accessibilityHidden(true)' in guide and 'repeatForever' not in guide
view = (ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text()
assert 'captureIntent: portrait ? .socialPhotos : .listingPhotos' in view and '@State private var musicSelection: VideoMusicSelection? = nil' in view
reelview=view[view.index('struct ReelStudioView:'):]
generation=reelview[reelview.index('    private func generate() {'):reelview.index('    private func generateWithSession()')]
assert generation.index('VideoPhotoFramingReader.read(') < generation.index('connection.run { generateWithSession() }')
assert 'framingSelectionKey == key' in generation and 'work.isPresented' in generation and 'AIConsent.shared.revocationRevision == consent' in generation
assert 'assessments.count == inputs.count' in generation and 'VideoFramingReviewPolicy.needsAcknowledgment(' in generation
make=view[view.index('    private var stepMakeCard:'):view.index('    private var videoHelpControls:')]
assert make.index('makeButton') < make.index('videoAdvancedControls') and '1080p' not in make and 'unconnected' not in make
assert 'your reel' not in view[view.index('    private var stepPhotosCard:'):view.index('    private func restoreServerVideoJob()')]

variants = [('actual',source,None),
    ('ignores-reduce-motion',source.replace('!reduceMotion && sceneIsActive && !userPaused','sceneIsActive && !userPaused'),'reduced motion, background and pause each stop animation'),
    ('wrong-framing-crop',source.replace('(1 - height) / 2','0'),'four-to-three photo has exact centered widescreen crop'),
    ('lost-license-evidence',source.replace('track.licenseEvidenceSHA256 == licenseEvidenceSHA256','true'),'changed license evidence cannot be silently restored'),
    ('ignored-exif-rotation',source.replace('(5...8).contains(exifOrientation) ? (height, width) : (width, height)', '(width, height)'), 'EXIF rotation determines imported displayed orientation'),
    ('lost-major-crop-admission',source.replace(r'assessments.contains(where: \.isMajorCrop) && selectionKey != acknowledgedKey','false'), 'large crops require aggregate review before generation'),
    ('stale-framing-acknowledgment',source.replace('selectionKey != acknowledgedKey','acknowledgedKey == nil'), 'changing the target format cannot reuse a crop acknowledgment'),
    ('lost-narration-ducking',source.replace('time < narrationDurationS ? selection.narrationDuckGain : selection.gain','selection.gain'),'music stays quiet under narration and recovers after speech')]
receipt={'passed':False,'sourceHashes':before,'runs':[],'limitations':['Foundation production purpose/orientation, ReduceMotion policy, exactsourcecrop and immutablemusicreceipt controls execute. SwiftUI/camera/audio playback/mix and realphone not executed here; final server audio mix has independent media tests. Artist-posted CC0 evidence is not a guarantee against third-party ownership or ContentID claims.']}
for name, production, expected in variants:
    directory=out/name;directory.mkdir(exist_ok=True); actual=directory/'Production.swift';actual.write_text(production)
    binary=directory/'checks'; build=subprocess.run(['xcrun','swiftc','-parse-as-library',str(actual),str(fixture),'-o',str(binary)],capture_output=True,text=True)
    (directory/'build.log').write_text(build.stdout+build.stderr)
    if build.returncode:raise SystemExit(build.stderr)
    run=subprocess.run([str(binary)],capture_output=True,text=True);(directory/'run.log').write_text(run.stdout+run.stderr)
    passed=run.returncode==0 if expected is None else run.returncode!=0 and expected in run.stderr
    receipt['runs'].append({'name':name,'exit':run.returncode,'passed':passed,'expectedRejection':expected,'stdout':run.stdout.strip()})
    if not passed:(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');raise SystemExit(name+' did not prove its boundary')
receipt['sourceHashesAtEnd']=hashes();receipt['passed']=receipt['sourceHashesAtEnd']==before;receipt['compiledNegativeControls']=len(variants)-1
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':receipt['passed'],'compiledNegativeControls':len(variants)-1,'receipt':str(out/'receipt.json')}))
