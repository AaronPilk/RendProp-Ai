#!/usr/bin/env python3
"""Compile the real Settings replay action with closed presentation/state inputs.
No video playback, app launch, auth, preferences, provider, Apple or UI actions.
"""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--evidence-dir',type=Path);args=a.parse_args()
out=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-intro-replay-'))).resolve();out.mkdir(parents=True,exist_ok=True)
settings=ROOT/'apps/ios/Rendprop/Screens/SettingsView.swift';video=ROOT/'apps/ios/Rendprop/Screens/QuickStartVideo.swift'
paths=[settings,video,Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
initial=hashes();s=settings.read_text();q=video.read_text()
def block(src,needle):
 begin=src.index(needle);i=src.index('{',begin);depth=1;j=i+1
 while depth:depth+=(src[j]=='{')-(src[j]=='}');j+=1
 return src[begin:j]
action=block(s,'private func watchIntroAgain()')
assert 'Button(action: watchIntroAgain)' in s
assert '.sheet(isPresented: $showQuickStart)' in s and 'QuickStartVideoView(returnLabel: "Skip checks and return to Settings")' in s
assert 'showIntroConfirm' not in s
assert 'var returnLabel = "Skip checks and return to sign-in"' in q
assert 'Button(returnLabel) { stopPlayback(); dismiss() }' in q
assert 'Button("Done") { stopPlayback(); dismiss() }' in q
base=subprocess.run(['git','show','f945758659192cfe4292822b66713a4bf90cb53a:apps/ios/Rendprop/Screens/QuickStartVideo.swift'],cwd=ROOT,text=True,capture_output=True,check=True).stdout
preserved={}
for anchor in ['private func stopPlayback()', '@discardableResult private func enableAudio(', '@MainActor private final class QuickStartPlaybackAudio']:
 current=block(q,anchor);assert current==block(base,anchor),anchor
 preserved[anchor]=hashlib.sha256(current.encode()).hexdigest()
source=r"""
import Foundation
final class UploadFixture { var running=true;func cancel(){running=false} }
final class SettingsReplayFixture {
 var showQuickStart=false;var hasOnboarded=true;var spaceTypeRaw="real_estate"
 let ownerID="synthetic-owner", plan="pro", profile="retained profile", reelReceipt="accepted-reel-request"
 let uploads=UploadFixture()
"""+action+r"""
 func tap(){watchIntroAgain()}
 func closeSheetBinding(){showQuickStart=false}
}
@main struct ReplayTests {
 static func main(){
  var count=0
  func check(_ ok:Bool,_ reason:String){guard ok else{fputs("FAIL: \(reason)\n",stderr);exit(1)};count+=1}
  let state=SettingsReplayFixture()
  state.tap()
  check(state.showQuickStart,"Settings presents the existing QuickStart movie")
  check(state.hasOnboarded,"watching intro must not reset onboarding")
  check(state.uploads.running,"watching intro must not cancel an upload")
  check(state.spaceTypeRaw=="real_estate" && state.profile=="retained profile","business/profile remain unchanged")
  check(state.ownerID=="synthetic-owner" && state.plan=="pro" && state.reelReceipt=="accepted-reel-request","account/plan/reel context remain unchanged")
  state.closeSheetBinding()
  check(!state.showQuickStart && state.hasOnboarded && state.uploads.running,"closing the presentation retains setup and work")
  state.tap()
  check(state.showQuickStart && state.hasOnboarded && state.uploads.running,"intro can reopen without a setup reset")
  print("PASS: \(count) actual Settings replay action assertions; closed state/presentation only")
 }
}
"""
controls=[('onboarding-reset','showQuickStart = true','showQuickStart = true; hasOnboarded = false','watching intro must not reset onboarding'),('upload-cancel','showQuickStart = true','showQuickStart = true; uploads.cancel()','watching intro must not cancel an upload')]
runs=[]
for name in ['positive']+[x[0] for x in controls]:
 text=source;reason=None
 if name!='positive':
  _,before,after,reason=next(x for x in controls if x[0]==name);assert text.count(before)==1;text=text.replace(before,after)
 path=out/(name+'.swift');path.write_text(text);binary=out/name
 compile=subprocess.run(['xcrun','swiftc','-parse-as-library',str(path),'-o',str(binary)],text=True,capture_output=True)
 (out/(name+'-compile.log')).write_text(compile.stdout+compile.stderr);assert compile.returncode==0,compile.stderr
 run=subprocess.run([str(binary)],text=True,capture_output=True);(out/(name+'.log')).write_text(run.stdout+run.stderr)
 assert run.returncode==(0 if name=='positive' else 1),(name,run.stdout,run.stderr)
 if reason:assert 'FAIL: '+reason in run.stderr,(name,run.stderr)
 runs.append({'name':name,'exit':run.returncode,'intended_fault':reason})
final=hashes();assert initial==final
receipt={'passed':True,'source_binding_matches':True,'assertions':7,'compiled_negative_controls':2,'source_sha256':initial,'end_source_sha256':final,'preserved_audio_and_dismissal_body_sha256':preserved,'runs':runs,'scope':'Actual Settings tap method with closed state/presentation. Sheet and return labels verified from source; unchanged actual audio ownership/cleanup bodies byte-bound to71. Shipping SwiftUI compile/physical playback remain root-owned.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'passed':True,'assertions':7,'compiled_negative_controls':2,'receipt':str(out/'receipt.json')}))
