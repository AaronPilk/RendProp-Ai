#!/usr/bin/env python3
"""Compiles actual native facts intent, client wire and AppModel sync/review bodies.
Owned synthetic transport; no network, camera, credentials, or Photos writes.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('--inject-fault',choices=['broad-wire','wrong-workspace','late-conflict','drop-receipt-scope','drop-archive-restore']);opts=parser.parse_args()
ROOT=Path(__file__).resolve().parents[3]
COMPILE_SECONDS=180
RUNTIME_SECONDS=90
OUT=Path(tempfile.mkdtemp(prefix='rendprop-listing-facts-sync-',dir='/tmp'))
spec=importlib.util.spec_from_file_location('extract',ROOT/'tools/audit/floor-measurement-sync-20261004/run.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
client=ROOT/'apps/ios/Rendprop/Networking/LiveAPIClient.swift';app=ROOT/'apps/ios/Rendprop/RendpropApp.swift'
a,b=client.read_text(),app.read_text();source=(Path(__file__).parent/'Fixture.swift.template').read_text()
cm={'CREATE':'    func createListing(_ listing: Listing)','UPDATE':'    func updateListing(_ listing: Listing)','UPDATE_MEASUREMENTS':'    func updateMeasurements(_ listing: Listing)','LISTING_BODY':'    private func listingBody(_ l: Listing,','MAP_LISTING':'    private func mapListing(_ dto: ListingDTO)','LISTING_DTO':'    private struct ListingDTO: Decodable','TOLERANT_MAP':'    struct TolerantStringMap: Decodable','DECODE':'    private func decode<T: Decodable>','PARSE_DATE':'    private static func parseDate(','ISO_STRING':'    private static func isoString(','WIRE_STATUS':'    private static func wireStatus(','LOCAL_STATUS':'    private static func localStatus('}
am={'IS_IN_WORKSPACE':'    func isInSelectedWorkspace(_ listing: Listing)', 'MODIFY':'    func modify(_ id: UUID,','SAVE_MEASUREMENTS':'    func saveMeasurements(_ plan: FloorMeasurementPlan,','RELOAD_SHARED':'    func reloadSharedMeasurements(_ id: UUID,','CONFIRM_LOCAL':'    func confirmLocalListingDetails(_ id: UUID)','FACTS_REVIEW_LOAD':'    func loadListingFactsReview(_ id: UUID)','FACTS_REVIEW_RESOLVE':'    func resolveListingFacts(_ review: ListingFactsReview,','SET_SOLD':'    func setSold(_ sold: Bool,','SET_PHOTO':'    func setMainPhoto(_ relPath:','SET_COORDINATE':'    func setCoordinate(lat:','MARK_DIRTY':'    func markDirty(_ id: UUID)','SYNC_LISTING':'    func syncListing(_ id: UUID)'}
extracted={**{k:mod.block(a,m) for k,m in cm.items()},**{k:mod.block(b,m) for k,m in am.items()}}
originalHashes={k:hashlib.sha256(v.encode()).hexdigest() for k,v in extracted.items()}
if opts.inject_fault=='broad-wire':
 before='json: try ListingFactsSync.body(listing)'
 assert extracted['UPDATE'].count(before)==1
 extracted['UPDATE']=extracted['UPDATE'].replace(before,'json: try listingBody(listing, forPatch: true)')
elif opts.inject_fault=='wrong-workspace':
 before='request.setValue(org.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")'
 assert extracted['UPDATE'].count(before)==1
 extracted['UPDATE']=extracted['UPDATE'].replace(before,'request.setValue("44444444-4444-4444-8444-444444444444", forHTTPHeaderField: "X-Org-Id")')
elif opts.inject_fault=='late-conflict':
 before='listings[i].serverID == snapshot.serverID, listings[i].serverOrgID == snapshot.serverOrgID,\n                   ListingFactsSync.hasSameLineage(snapshot, listings[i]) {'
 assert extracted['SYNC_LISTING'].count(before)==1
 extracted['SYNC_LISTING']=extracted['SYNC_LISTING'].replace(before,'listings[i].serverID == snapshot.serverID, listings[i].serverOrgID == snapshot.serverOrgID {')
elif opts.inject_fault=='drop-receipt-scope':
 before='        guard dto.id.flatMap(UUID.init(uuidString:)) == target,\n              dto.orgId.flatMap(UUID.init(uuidString:)) == org else { throw CloudSyncError.invalidResponse }\n'
 for key in ['UPDATE','UPDATE_MEASUREMENTS']:
  assert extracted[key].count(before)==1
  extracted[key]=extracted[key].replace(before,'')
elif opts.inject_fault=='drop-archive-restore':
 before='; if !sold { $0.cloudArchived = false }'
 assert extracted['SET_SOLD'].count(before)==1
 extracted['SET_SOLD']=extracted['SET_SOLD'].replace(before,'')
for k,v in extracted.items():source=source.replace('__'+k+'__',v)
assert not re.search(r'__[A-Z_]+__',source)
fixture=OUT/'ActualListingFactsSync.swift';fixture.write_text(source)
models=[ROOT/('apps/ios/Rendprop/'+p) for p in ['Models/Listing.swift','Models/ListingClientContact.swift','Models/Money.swift','Networking/NativeReelDraft.swift','Auth/AnonymousAdoptionRecovery.swift','Auth/AdoptionLocalBindings.swift','Networking/WorkspaceSync.swift']]
files=[*models,client,app,Path(__file__).resolve(),Path(__file__).parent/'Fixture.swift.template',ROOT/'tools/audit/floor-measurement-sync-20261004/run.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
receipt={'output':str(OUT),'fault':opts.inject_fault,'sourceHashes':{str(p.relative_to(ROOT)):sha(p) for p in files},'originalExtractedHashes':originalHashes,'extractedHashes':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in extracted.items()},'fixtureSHA256':sha(fixture),'scope':'Actual native methods; synthetic transport/Auth/workspace. SQL races and real phone acceptance separate.','commands':[]}
for name,args in [('compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,models),str(fixture),'-o',str(OUT/'checks')]),('run',[str(OUT/'checks')])]:
 timeout=COMPILE_SECONDS if name=='compile' else RUNTIME_SECONDS;log=OUT/(name+'.log')
 try:p=subprocess.run(args,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 except subprocess.TimeoutExpired as error:
  partial=error.stdout or b'';log.write_bytes(partial.encode() if isinstance(partial,str) else partial)
  receipt['commands'].append({'name':name,'exit':None,'timedOut':True,'timeoutSeconds':timeout,'logSHA256':sha(log)})
  receipt['passed']=False;receipt['sourceBoundAtEnd']=all(sha(ROOT/k)==v for k,v in receipt['sourceHashes'].items())
  (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(name,'timed out after',timeout,'seconds');print('Evidence:',OUT)
  raise SystemExit(1)
 log.write_text(p.stdout)
 receipt['commands'].append({'name':name,'exit':p.returncode,'timeoutSeconds':timeout,'logSHA256':sha(log)})
 if name=='run' and p.returncode==0:receipt['assertions']=int(re.search(r'(\d+) assertions',p.stdout)[1])
 expected={'broad-wire':'Actual wire contains only explicit intent','wrong-workspace':'Actual facts write is workspace-bound','late-conflict':'Late conflict cannot poison an explicitly adopted shared version','drop-receipt-scope':'Ordinary facts receipt must match submitted listing and workspace','drop-archive-restore':'Clearing sold restores a Studio-archived listing explicitly'}.get(opts.inject_fault)
 receipt['passed']=name=='run' and (p.returncode==1 and expected in p.stdout if expected else p.returncode==0)
 if expected:receipt['expectedRejection']=expected
 if name=='run':
  receipt['sourceBoundAtEnd']=all(sha(ROOT/k)==v for k,v in receipt['sourceHashes'].items())
  receipt['passed']=receipt['passed'] and receipt['sourceBoundAtEnd']
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(name,p.returncode,p.stdout[-3500:]);print('Evidence:',OUT)
 if (name=='compile' and p.returncode) or (name=='run' and not receipt['passed']):raise SystemExit(1)
assert all(sha(ROOT/k)==v for k,v in receipt['sourceHashes'].items())
