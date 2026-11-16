#!/usr/bin/env python3
"""Execute actual native style catalog/decoder; no UI/media/provider calls."""
from pathlib import Path
import hashlib, json, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(tempfile.mkdtemp(prefix='rendprop-stage-styles-'))
inputs=['apps/ios/Rendprop/Models/Render.swift','apps/ios/Rendprop/Screens/FlythroughDetailView.swift','tests/phase1/run-staging-styles.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p:sha(ROOT/p) for p in inputs}
render=(ROOT/inputs[0]).read_text();view=(ROOT/inputs[1]).read_text()
def block(text,anchor):
 start=text.index(anchor);opening=text.index('{',start);depth=0
 for i in range(opening,len(text)):
  if text[i]=='{':depth+=1
  elif text[i]=='}':
   depth-=1
   if depth==0:return text[start:i+1]
 raise AssertionError(anchor)
style=block(view,'private struct StagingStyle:');decoder=block(render,'enum DesignStyle:')
assert 'Button("Contemporary") { aiEdit(p, "stage", style: "contemporary") }' in view
assert 'Button { aiEdit(p, "stage", style: "contemporary") } label: { Text("Contemporary") }' in view
assert 'style: "scandinavian"' not in view,'New-choice UI must not send legacy Scandinavian'
source='import Foundation\nstruct SpaceType { static var current: Self { Self() }; var spaceNoun: String { "home" } }\n'+decoder+'\n'+style+'''
@main struct Test {
 static func require(_ value: Bool,_ reason: String) { if !value { fputs("FAIL: \\(reason)\\n",stderr);exit(1) } }
 static func main() throws {
  require(StagingStyle.all.map(\\.id)==["modern","rustic","minimalist","contemporary"],"distinct current preset IDs")
  require(StagingStyle.all.map(\\.label)==["Modern","Rustic","Minimalist","Contemporary"],"current visible labels")
  let old=try JSONDecoder().decode(DesignStyle.self,from:Data("\\"scandinavian\\"".utf8))
  require(old.rawValue=="scandinavian" && old.displayName=="Scandinavian","legacy display not relabelled")
  require(old.blurb.contains("hygge"),"legacy style semantics retained")
  let current=try JSONDecoder().decode(DesignStyle.self,from:Data("\\"contemporary\\"".utf8))
  require(current.displayName=="Contemporary" && current.blurb.contains("curved"),"new Contemporary semantics")
  require(tryJSON(old)=="\\"scandinavian\\"","legacy persisted wire value retained")
  print("PASS: actual native4-choice catalog and historical/new style decoder")
 }
 static func tryJSON(_ value: DesignStyle)->String {String(data:try! JSONEncoder().encode(value),encoding:.utf8)!}
}
'''
controls=[('relabelled-wire', 'StagingStyle(id: "contemporary", label: "Contemporary")','StagingStyle(id: "scandinavian", label: "Contemporary")','distinct current preset IDs'),('relabelled-history','case .scandinavian: return "Scandinavian"','case .scandinavian: return "Contemporary"','legacy display not relabelled')]
for name,variant,reason in [('positive',source,None)]+[(n,source.replace(a,b),r) for n,a,b,r in controls]:
 path=OUT/(name+'.swift');path.write_text(variant)
 compile=subprocess.run(['xcrun','swiftc','-parse-as-library',str(path),'-o',str(OUT/name)],capture_output=True,text=True)
 (OUT/(name+'-compile.log')).write_text(compile.stdout+compile.stderr);assert compile.returncode==0,compile.stderr
 run=subprocess.run([str(OUT/name)],capture_output=True,text=True);(OUT/(name+'.log')).write_text(run.stdout+run.stderr)
 assert run.returncode==(1 if reason else 0),(name,run.stderr)
 if reason:assert reason in run.stderr,(name,run.stderr)
assert before=={p:sha(ROOT/p) for p in inputs}
receipt={'passed':True,'sourceHashes':before,'actualCatalogSHA256':hashlib.sha256(style.encode()).hexdigest(),'actualDecoderSHA256':hashlib.sha256(decoder.encode()).hexdigest(),'compiledNegativeControls':[v[0] for v in controls],'scope':'Actual native catalog/decoder, all visible action-menu style requests. No phone UI/visual/provider output proof.','networkCalls':0,'paidProviderCalls':0,'AppleCalls':0}
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':True,'receipt':str(OUT/'receipt.json')}))
