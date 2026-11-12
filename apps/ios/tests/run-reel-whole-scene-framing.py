#!/usr/bin/env python3
"""Actual one-pass clean Instagram compositor proof; procedural local media only."""
from pathlib import Path
import argparse,hashlib,json,platform,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);p.add_argument('--simulator');a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-clean-reel-'))).resolve();out.mkdir(parents=True,exist_ok=True)
composer=root/'apps/ios/Rendprop/Render/ReelComposer.swift'
voice=root/'apps/ios/Rendprop/Voice/VoiceTypes.swift';captions=root/'apps/ios/Rendprop/Voice/CaptionRenderer.swift'
fixture=root/'apps/ios/tests/ReelWholeSceneFramingTests.swift'
detail=root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
paths=[composer,voice,captions,fixture,detail,Path(__file__).resolve()]
def hashes():return{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
def command(name,argv,timeout=240,check=True):
 r=subprocess.run(argv,capture_output=True,text=True,timeout=timeout);(out/(name+'.log')).write_text(r.stdout+r.stderr)
 if check:assert r.returncode==0,name+': '+r.stdout+r.stderr
 return r
text=composer.read_text();view=detail.read_text()
assert 'let prepared = await prepare(shots, renderSize: renderSize)' in text
assert 'normalizeIfNeeded' not in text and 'CIGaussianBlur' not in text,'new reel composition/fallback must contain no synthetic blur'
assert 'static func reelSource(_ image: UIImage, aspect: String) -> UIImage { image }' in view,'provider input must remain the full selected photo'
assert 'maxDimension: 2048)' in view and 'compressionQuality: 0.95)' in view
fill='let scale = max(renderSize.width / displayW, renderSize.height / displayH)'
assert text.count(fill)==1
receipt={'passed':False,'start_source_sha256':hashes(),'runs':[],'limitations':['Procedural encoded video executes actual ReelComposer, transform, captions, transitions and real PCM voice. No provider or physical phone; this proves a single final crop without synthetic padding, not generation fidelity or recovered detail. Full selected source preparation is unchanged and is separately actual-UIKit/wire bound.']}
old='let lastFrameStart = await finalSourceFrameStart(track: lastSrcTrack, range: layout.lastSrcRange)\n                ?? CMTimeMaximum(layout.lastSrcRange.start, CMTimeSubtract(srcEnd, frameDuration))'
variants=[('actual',text,None),
 ('negative-letterbox',text.replace(fill,'let scale = min(renderSize.width / displayW, renderSize.height / displayH)'),'single crop fills encoded frame edges without black bars'),
 ('negative-extra-zoom',text.replace(fill,fill+' * 1.2'),'delivery is one centered cover crop with source geometry and orientation'),
 ('negative-ignore-orientation',text.replace('var t = preferredTransform','var t = CGAffineTransform.identity'),'delivery is one centered cover crop with source geometry and orientation'),
 ('negative-thirty-fps-freeze',text.replace(old,'let lastFrameStart = CMTimeMaximum(layout.lastSrcRange.start, CMTimeSubtract(srcEnd, frameDuration))'),'voice hold selects the actual final source frame instead of assuming thirty fps')]
try:
 sdk=command('sdk',['xcrun','--sdk','iphonesimulator','--show-sdk-path'],30).stdout.strip()
 devices=json.loads(command('simulators',['xcrun','simctl','list','devices','available','-j'],30).stdout)['devices']
 candidates=[d for rt,ds in devices.items() if 'iOS' in rt for d in ds if d['isAvailable']]
 device=next(d for d in candidates if d['udid']==a.simulator) if a.simulator else next(d for d in candidates if d['state']=='Booted')
 receipt['simulator']=device['udid'];arch='arm64' if platform.machine()=='arm64' else 'x86_64'
 for name,code,reason in variants:
  assert reason is None or code!=text,name+' mutation missing'
  # Expose exactly the source-bound hold-range decision; no production change.
  hold_start=code.index('            let srcEnd = CMTimeAdd(layout.lastSrcRange.start, layout.lastSrcRange.duration)')
  hold_end=code.index('            if stillRange.duration',hold_start)
  decision=code[hold_start:hold_end].replace('layout.lastSrcRange','range')
  exposed='    static func auditedSourceHoldRange(track lastSrcTrack: AVAssetTrack, range: CMTimeRange) async -> CMTimeRange {\n'+decision+'        return stillRange\n    }\n'
  point=code.index('    private static func holdLastFrame(')
  code=code[:point]+exposed+code[point:]
  path=out/(name+'-composer.swift');path.write_text(code);binary=out/name
  command(name+'-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',arch+'-apple-ios16.0-simulator','-sdk',sdk,str(path),str(voice),str(captions),str(fixture),'-o',str(binary)])
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
print('PASS:',receipt['observations']['checks'],'actual clean encoded assertions +',len(variants)-1,'compiled negative controls;',out/'receipt.json')
