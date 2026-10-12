#!/usr/bin/env python3
"""Actual streaming reader/CI/writer and composer proof; procedural local media only."""
from pathlib import Path
import argparse,hashlib,json,platform,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);p.add_argument('--simulator');a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-whole-scene-'))).resolve();out.mkdir(parents=True,exist_ok=True)
helper=root/'apps/ios/Rendprop/Render/ReelWholeSceneFraming.swift'
composer=root/'apps/ios/Rendprop/Render/ReelComposer.swift'
voice=root/'apps/ios/Rendprop/Voice/VoiceTypes.swift';captions=root/'apps/ios/Rendprop/Voice/CaptionRenderer.swift'
fixture=root/'apps/ios/tests/ReelWholeSceneFramingTests.swift'
paths=[helper,composer,voice,captions,fixture,Path(__file__).resolve()]
def hashes():return{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
def command(name,argv,timeout=240,check=True):
 r=subprocess.run(argv,capture_output=True,text=True,timeout=timeout);(out/(name+'.log')).write_text(r.stdout+r.stderr)
 if check:assert r.returncode==0,name+': '+r.stdout+r.stderr
 return r
receipt={'passed':False,'start_source_sha256':hashes(),'runs':[],'limitations':['Procedural encoded video executes actual AVAssetReader, CoreImage fit/blur, AVAssetWriter and full ReelComposer/CaptionRenderer. No provider or physical phone; this cannot restore provider-cropped pixels or certify real listing visual acceptance. Existing composer takes optional independent voice audio; framing modifies video copies only.']}
text=helper.read_text();composer_text=composer.read_text()
variants=[('actual',text,None),
 ('negative-cover-crop',text.replace('let fit = min(','let fit = max('),'sharp foreground retains the whole raw provider frame and its orientation'),
 ('negative-black-padding',text.replace('foreground.composited(over: background)','foreground.composited(over: CIImage(color: .black).cropped(to: canvas))'),'same-scene matte fills encoded delivery edges without black bars'),
 ('negative-ignore-orientation',text.replace('orientedImage(CIImage(cvPixelBuffer: pixels), preferred: preferred)','CIImage(cvPixelBuffer: pixels)'),'sharp foreground retains the whole raw provider frame and its orientation'),
 ('negative-sharp-backdrop',text.replace('.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(renderSize.width, renderSize.height) * 0.035])',''),'delivery padding is blurred same-scene color rather than a sharp duplicate'),
 ('negative-reencode-matching',text.replace('if abs(sourceRatio - targetRatio) < 0.00001 { return source }','if false { return source }'),'matching delivery shape skips an unnecessary encode and keeps original bytes'),
 ('negative-thirty-fps-freeze',text,'voice hold selects the actual final source frame instead of assuming thirty fps')]
try:
 sdk=command('sdk',['xcrun','--sdk','iphonesimulator','--show-sdk-path'],30).stdout.strip()
 devices=json.loads(command('simulators',['xcrun','simctl','list','devices','available','-j'],30).stdout)['devices']
 candidates=[d for rt,ds in devices.items() if 'iOS' in rt for d in ds if d['isAvailable']]
 device=next(d for d in candidates if d['udid']==a.simulator) if a.simulator else next(d for d in candidates if d['state']=='Booted')
 receipt['simulator']=device['udid'];arch='arm64' if platform.machine()=='arm64' else 'x86_64'
 for name,code,reason in variants:
  assert reason is None or code!=text or name=='negative-thirty-fps-freeze',name+' mutation missing'
  path=out/(name+'.swift');path.write_text(code);binary=out/name
  compositor_code=composer_text
  if name=='negative-thirty-fps-freeze':
   old='let lastFrameStart = await finalSourceFrameStart(track: lastSrcTrack, range: layout.lastSrcRange)\n                ?? CMTimeMaximum(layout.lastSrcRange.start, CMTimeSubtract(srcEnd, frameDuration))'
   assert old in composer_text
   compositor_code=composer_text.replace(old,'let lastFrameStart = CMTimeMaximum(layout.lastSrcRange.start, CMTimeSubtract(srcEnd, frameDuration))')
  # Project the exact production hold-range decision into a callable test
  # method. The stream reader, frame selection and hold expression remain
  # source-bound; private visibility and the surrounding Layout are closed.
  hold_start=compositor_code.index('            let srcEnd = CMTimeAdd(layout.lastSrcRange.start, layout.lastSrcRange.duration)')
  hold_end=compositor_code.index('            if stillRange.duration',hold_start)
  decision=compositor_code[hold_start:hold_end]
  assert 'let stillRange = CMTimeRange' in decision
  decision=decision.replace('layout.lastSrcRange','range')
  exposed='    static func auditedSourceHoldRange(track lastSrcTrack: AVAssetTrack, range: CMTimeRange) async -> CMTimeRange {\n'+decision+'        return stillRange\n    }\n'
  point=compositor_code.index('    private static func holdLastFrame(')
  compositor_code=compositor_code[:point]+exposed+compositor_code[point:]
  compositor=out/(name+'-composer.swift');compositor.write_text(compositor_code)
  command(name+'-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',arch+'-apple-ios16.0-simulator','-sdk',sdk,str(path),str(compositor),str(voice),str(captions),str(fixture),'-o',str(binary)])
  media=out/(name+'-media');result=command(name,['xcrun','simctl','spawn',device['udid'],str(binary),str(media)]+([] if reason is None or name=='negative-thirty-fps-freeze' else ['--framing-only']),360,False)
  log=result.stdout+result.stderr;expected=result.returncode==0 if reason is None else result.returncode!=0 and 'Precondition failed: '+reason in log
  receipt['runs'].append({'name':name,'exit_code':result.returncode,'expected_result':expected,'expected_failure':reason});binary.unlink()
  assert expected,name+': '+log
  if reason is None:receipt['observations']=json.loads((media/'result.json').read_text())
except BaseException as e:receipt['failure']=str(e);raise
finally:
 receipt['end_source_sha256']=hashes();receipt['source_binding_matches']=receipt['start_source_sha256']==receipt['end_source_sha256']
 receipt['passed']='failure' not in receipt and len(receipt['runs'])==len(variants) and receipt['source_binding_matches'] and all(x['expected_result'] for x in receipt['runs'])
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS:',receipt['observations']['checks'],'actual encoded assertions +',len(variants)-1,'compiled negative controls;',out/'receipt.json')
