#!/usr/bin/env python3
"""Run actual cross-platform ImageIO browser-original conversion, no UI/network.
Uses actual HEIC encoder, full pixels, orientation, P3 color and retry-byte proof.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-browser-original-'));out.mkdir(parents=True,exist_ok=True)
paths=['apps/ios/Rendprop/Photos/PhotoBrowserOriginal.swift','apps/ios/tests/PhotoBrowserOriginalTests.swift','apps/ios/tests/run-photo-browser-original.py','apps/ios/Rendprop/Upload/UploadManager.swift']
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
before={p:sha(ROOT/p) for p in paths}
source=(ROOT/paths[0]).read_text();upload=(ROOT/paths[3]).read_text();start=upload.index('    func uploadOriginal(');end=upload.index('\n    /// Upload ONE',start);body=upload[start:end]
assert 'PhotoBrowserOriginal.prepare(fileURL)' in body and 'fileURL: prepared.url' in body and 'defer { prepared.removeTemporaryFiles() }' in body
assert 'contentType = DirectUploader.uploadContentType(for: prepared.url, kind: "photo")' in body
assert '["image/jpeg", "image/png", "image/webp"].contains(contentType)' in body
assert 'context.matches(owner: AuthStore.shared.userID,' in body and 'try Task.checkCancellation()' in body
base=['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/paths[0]),str(ROOT/paths[1]),'-o',str(out/'runtime')]
r=subprocess.run(base,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stderr
r=subprocess.run([str(out/'runtime')],capture_output=True,text=True,timeout=90);(out/'runtime.log').write_text(r.stdout+r.stderr);assert r.returncode==0,(r.stdout,r.stderr)
controls=[]
for name,old,new,reason in [('degraded-jpeg','output[kCGImageDestinationLossyCompressionQuality] = 1.0','output[kCGImageDestinationLossyCompressionQuality] = 0.05','highquality color detail'),('wrong-orientation','output[kCGImagePropertyOrientation] = orientation','output[kCGImagePropertyOrientation] = 1','verify the browser copy'),('damaged-compatible-original','try FileManager.default.copyItem(at: sourceURL, to: target)','try Data("not-raw".utf8).write(to: target)','alreadybrowsercompatible bytes')]:
 assert old in source
 f=out/(name+'.swift');f.write_text(source.replace(old,new,1));cmd=list(base);cmd[cmd.index(str(ROOT/paths[0]))]=str(f);cmd[-1]=str(out/name)
 c=subprocess.run(cmd,capture_output=True,text=True);(out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
 e=subprocess.run([str(out/name)],capture_output=True,text=True,timeout=90);(out/(name+'.log')).write_text(e.stdout+e.stderr);assert e.returncode==1 and reason in e.stderr,(name,e.stdout,e.stderr)
 controls.append({'name':name,'compiled':True,'rejected':True,'reason':reason})
assert before=={p:sha(ROOT/p) for p in paths},'Consumed source changed during proof'
r={'passed':True,'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':before,'actualUploadOriginalBodySHA256':hashlib.sha256(body.encode()).hexdigest(),'negativeControls':controls,'scope':'Actual ImageIO helper on macOS using a real HEIC source with rotated orientation and DisplayP3 content. JPEG uses full dimensions/no crop/highquality1.0 with measured color-detail bound. Correct MIMEextension and exact rawretention/pass-through/retry determinism. Same production helper iPhoneOS SDK typecheck is a separate proof. No actual cloud upload or realphotoUI/provider calls.','networkCalls':0,'AppleCalls':0,'paidProviderCalls':0,'UIExecutions':0}
(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':True,'receipt':str(out/'receipt.json'),'negativeControls':len(controls)}))
