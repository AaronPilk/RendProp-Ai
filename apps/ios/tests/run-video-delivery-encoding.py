#!/usr/bin/env python3
"""Headless kernel-only actual composer encoding; never opens Simulator UI."""
from pathlib import Path
import argparse,hashlib,json,platform,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);p.add_argument('--simulator');a=p.parse_args()
out=(a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-video-delivery-'))).resolve();out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/'apps/ios/Rendprop/Render/ReelComposer.swift',ROOT/'apps/ios/Rendprop/Render/VideoAspectChoice.swift',ROOT/'apps/ios/Rendprop/Voice/VoiceTypes.swift',ROOT/'apps/ios/Rendprop/Voice/CaptionRenderer.swift',ROOT/'apps/ios/tests/VideoDeliveryEncodingTests.swift',ROOT/'apps/ios/Rendprop/Models/ListingVideo.swift',ROOT/'apps/ios/Rendprop/Render/ListingVideoPreparation.swift',ROOT/'apps/ios/Rendprop/Render/VideoMusicContract.swift',Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before=hashes()
def command(label,cmd,timeout=240):
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout);(out/(label+'.log')).write_text(r.stdout+r.stderr);return r
sdk=command('sdk',['xcrun','--sdk','iphonesimulator','--show-sdk-path']).stdout.strip()
r=command('kernels',['xcrun','simctl','list','devices','available','-j']);assert r.returncode==0,r.stderr
kernels=[d for runtime,devices in json.loads(r.stdout)['devices'].items() if 'iOS' in runtime for d in devices if d.get('isAvailable') and d['state']=='Booted']
kernel=next((d for d in kernels if d['udid']==a.simulator),None) if a.simulator else next(iter(kernels),None)
assert kernel,'A previously booted headless iOS kernel is required; this harness never boots one or opens Simulator UI'
arch='arm64' if platform.machine()=='arm64' else 'x86_64'
composer=paths[0].read_text()
anchor='let prepared = await prepare(shots, renderSize: renderSize)'
assert composer.count(anchor)==1
metadata=paths[5].read_text()
variants=[('actual',composer,None,metadata),('eight-shot-truncation',composer.replace(anchor,'let prepared = await prepare(Array(shots.prefix(8)), renderSize: renderSize)'),'12-shot video retains every clip in its full timeline',metadata),('reversed-shot-order',composer.replace(anchor,'let prepared = await prepare(Array(shots.reversed()), renderSize: renderSize)'),'all twelve source shots retain exact order in encoded video',metadata),('listing-brand-leak',composer,'listing title-card policy suppresses app branding before encoding',metadata.replace('aspect == "9:16" ? requested : nil','requested'))]
runs=[]
for name,source,expected,policy in variants:
 copied=out/(name+'-composer.swift');copied.write_text(source);binary=out/name
 policy_path=out/(name+'-policy.swift');policy_path.write_text(policy)
 c=command(name+'-compile',['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',arch+'-apple-ios16.0-simulator','-sdk',sdk,str(copied),*[str(policy_path if x == paths[5] else x) for x in paths[1:-1]],'-o',str(binary)])
 assert c.returncode==0,(name,c.stderr)
 media=Path(tempfile.mkdtemp(prefix=name+'-media-',dir=out));r=command(name,['xcrun','simctl','spawn',kernel['udid'],str(binary),str(media)],timeout=180)
 text=r.stdout+r.stderr
 if expected:assert r.returncode!=0 and 'Precondition failed: '+expected in text,(name,text)
 else:assert r.returncode==0,(name,text)
 runs.append({'name':name,'exit':r.returncode,'expectedRejection':expected,'compiledComposerSHA256':hashlib.sha256(copied.read_bytes()).hexdigest()})
 observations=json.loads((media/'result.json').read_text()) if expected is None else None
 if observations:actual_observations=observations
 binary.unlink()
after=hashes();assert before==after,'Encoder source changed during proof'
receipt={'passed':True,'sourceHashes':before,'sourceHashesAtEnd':after,'runs':runs,'compiledNegativeControls':3,'observations':actual_observations,'environment':{'kernel':kernel['udid'],'name':kernel['name'],'headlessCLIOnly':True,'SimulatorUIOpened':False,'AppLaunched':False},'limitations':['Actual UIKit source raster and AVFoundation compositor encoding. Procedural synthetic clips only; no real phone or provider output quality claim. Both output canvases and every shot of the twelve-clip timeline were independently decoded and checked.']}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':True,'compiledNegativeControls':3,'receipt':str(out/'receipt.json')}))
