#!/usr/bin/env python3
"""Actual opening policy, Home gates, legacy Aerial tap and plan consumer.
Closed navigation/session interfaces only; no UI, provider, account or Apple work.
Saved/pending operations are bound byte-for-byte to the pre-change native source.
"""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser(); a.add_argument('--evidence-dir',type=Path); args=a.parse_args()
out=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-aerial-launch-'))).resolve();out.mkdir(parents=True,exist_ok=True)
ios=ROOT/'apps/ios/Rendprop'
names=['Support/LaunchFeatureAvailability.swift','RendpropApp.swift','Screens/FlythroughDetailView.swift','Purchases/Products.swift','Screens/SettingsView.swift','Screens/HomeListingsView.swift','Coach/CoachModel.swift','Coach/AskAIButton.swift','Purchases/PaywallHost.swift','Purchases/PaywallView.swift','Plan/PlanBanner.swift']
manifest_path=ROOT/'apps/ios/tests/LaunchPreservedBodies71.json'
paths=[ios/name for name in names]+[Path(__file__).resolve(),ROOT/'apps/ios/tests/AerialLaunchAvailabilityTests.swift',manifest_path]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start=hashes(); src={n:(ios/n).read_text() for n in names}
def block(source,needle):
 start=source.index(needle);opening=source.index('{',start);depth=1;end=opening+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
app=src['RendpropApp.swift'];fly=src['Screens/FlythroughDetailView.swift']
manifest=json.loads(manifest_path.read_text())
assert manifest['schema']==1 and manifest['reviewed_baseline_commit']=='f945758659192cfe4292822b66713a4bf90cb53a'
expected_preserved=manifest['files']['apps/ios/Rendprop/Screens/FlythroughDetailView.swift']
preserved=['private struct PendingAerialJob:','private struct AerialMeta:','private func seedIfNeeded()', 'private func resume(_ pending:', 'private func resumeWithSession(_ pending:', 'private func pollAndStore(_ pending:']
preserved_hashes={}
for needle in preserved:
 actual=block(fly,needle);digest=hashlib.sha256(actual.encode()).hexdigest()
 assert digest==expected_preserved[needle],f'accepted/saved aerial operation changed: {needle}'
 preserved_hashes[needle]=digest
toolbox=block(fly,'private struct ListingToolboxGrid:')
assert 'ListingToolCard(title: "Aerial intro", sub: sample ? createFirst : "Saved clips · eligible paid opening"' in toolbox
assert 'detail.aerialOpening' in toolbox and 'AerialOpeningScreen(listing: destinationListing())' in toolbox
assert 'featureButton(.aerial)' in block(app,'private var featureGrid:')
assert 'LaunchFeatureAvailability.canCreateOpening' in block(app,'private func open(_ feature:')
assert 'LaunchFeatureAvailability.canCreateOpening' in block(app,'private func go(_ listing:')
assert 'PendingAerialJob.load(for: currentListing.id) != nil' in block(fly,'private var toolboxSection:')
assert 'detail.resumeAerial' in block(fly,'private struct ListingToolboxSection:')
assert 'LaunchFeatureAvailability.canGenerateAerial' in block(fly,'private func generateWithSession()').split('let job = try await api.aiVideoAerial')[0]
assert '!LaunchFeatureAvailability.canGenerateAerial' in block(fly,'@ViewBuilder private var formSection:')
assert 'if LaunchFeatureAvailability.canGenerateAerial' in block(fly,'private var resultSection:')
assert 'usageRow("Aerial intros"' not in block(src['Screens/SettingsView.swift'],'private func usageRows(')
for n in ['Purchases/PaywallHost.swift','Purchases/PaywallView.swift','Plan/PlanBanner.swift']:
 assert 'AI photo edits, reels, aerial intros and more listings' not in src[n]
assert 'Choose an original exterior photo showing the front' in src['Screens/HomeListingsView.swift']
assert 'case .tour, .reel, .aerial, .motionClip: return true' in block(fly,'struct ListingMediaItem:')
assert 'extraClipURLs: currentListing.aerialURL.map { [$0] } ?? []' in fly
interfaces = r"""
import Foundation
enum ProjectFeature: Equatable { case tour, photos, photoStudio, reel, aerial }
struct Listing { let id:UUID; var isSample=false }
struct ProjectRoute { let listing:Listing; let feature:ProjectFeature }
enum ProjectGateSheet { case start(ProjectFeature), pick(ProjectFeature), aerial(Listing), reel(Listing) }
enum Config { static var useLiveBackend=false }
enum WorkspaceContext { static var selectedOrgID:UUID? }
struct Connection { let onRun:()->Void; func run(_ action:()->Void) { onRun();action() } }
@MainActor final class HomeFixture {
 var projects:[Listing]=[]; var gate:ProjectGateSheet?;var route:ProjectRoute?;var showRoute=false;var listingsTrips=0
 func goToListings(){listingsTrips+=1}
"""
source=src['Support/LaunchFeatureAvailability.swift']+interfaces+block(app,'private func open(_ feature:')+'\n'+block(app,'private func go(_ listing:')+r"""
 func launch(_ feature:ProjectFeature){open(feature)}
 func direct(_ listing:Listing,_ feature:ProjectFeature){go(listing,feature)}
}
@MainActor final class AerialFixture {
 enum Phase{case form,generating,result};var phase=Phase.form;let listing=Listing(id:UUID());var isSavingPhoto=false
 var sessionCalls=0;var postBoundaryCalls=0
 var connection:Connection{Connection(onRun:{self.sessionCalls+=1})}
 func generateWithSession(){postBoundaryCalls+=1}
"""+block(fly,'private func generate()')+r"""
 func tap(){generate()}
}
"""+block(src['Purchases/Products.swift'],'struct PlanAllowances:')+'\n'+(ROOT/'apps/ios/tests/AerialLaunchAvailabilityTests.swift').read_text()
controls=[
 ('enabled-legacy-launch','static let canGenerateAerial = false','static let canGenerateAerial = true','legacy aerial generator remains unavailable'),
 ('home-open-uses-legacy-flag','guard feature != .aerial || LaunchFeatureAvailability.canCreateOpening else { return }','guard feature != .aerial || LaunchFeatureAvailability.canGenerateAerial else { return }','Home opening starts a listing when none exists'),
 ('home-route-uses-legacy-flag','guard feature != .aerial || LaunchFeatureAvailability.canCreateOpening else { return }','guard feature != .aerial || LaunchFeatureAvailability.canGenerateAerial else { return }','direct opening route keeps its exact listing'),
 ('aerial-tap-unfenced','guard LaunchFeatureAvailability.canGenerateAerial,\n              phase != .generating','guard phase != .generating','legacy aerial tap cannot ask for session or reach dispatch'),
 ('paid-benefit-aerial','"Other AI tools have separate plan limits",','"Other AI tools have separate plan limits", "2 aerial intros",','paid plan benefits cannot include aerial generation'),
]
runs=[]
for label in ['positive']+[c[0] for c in controls]:
 text=source;expected=None
 if label!='positive':
  _,before,after,expected=next(c for c in controls if c[0]==label)
  if label=='home-open-uses-legacy-flag': text=text.replace(before,after,1)
  elif label=='home-route-uses-legacy-flag':
   first=text.index(before); second=text.index(before,first+len(before));text=text[:second]+text[second:].replace(before,after,1)
  else: assert text.count(before)==1,(label,text.count(before));text=text.replace(before,after)
 swift=out/(label+'.swift');swift.write_text(text);binary=out/label
 compile=subprocess.run(['xcrun','swiftc','-parse-as-library',str(swift),'-o',str(binary)],capture_output=True,text=True)
 (out/(label+'-compile.log')).write_text(compile.stdout+compile.stderr);assert compile.returncode==0,(label,compile.stderr)
 run=subprocess.run([str(binary)],capture_output=True,text=True);(out/(label+'.log')).write_text(run.stdout+run.stderr)
 assert run.returncode==(0 if label=='positive' else 1),(label,run.stdout,run.stderr)
 if expected:assert 'FAIL: '+expected in run.stderr,(label,run.stderr)
 runs.append({'name':label,'exit':run.returncode,'expected_fault':expected})
end=hashes();assert start==end,'source changed during gate'
receipt={'passed':True,'source_binding_matches':True,'source_sha256':start,'end_source_sha256':end,'runs':runs,'compiled_negative_controls':len(controls),'preserved_accepted_and_saved_operation_sha256':preserved_hashes,'scope':'Actual opening/legacy policy + actual Home open/go + legacy Aerial generate tap body + actual PlanAllowances. Session/dispatch/navigation closed boundaries; new opening UI and legacy second POST guard/read/export are source assertions and preserved body hashes, not live provider tests.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'passed':True,'compiled_negative_controls':len(controls),'receipt':str(out/'receipt.json')}))
