#!/usr/bin/env python3
"""Extract actual form/edit-sheet and sync methods; compile against frozen source.
Synthetic Auth/workspace/API only. Does not run SwiftUI, phone/provider/Photos.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('--inject-fault',choices=['broad-form','fresh-baseline','price-rounding']);opts=parser.parse_args()
ROOT=Path(__file__).resolve().parents[3];OUT=Path(tempfile.mkdtemp(prefix='rendprop-listing-form-intent-',dir='/tmp'))
spec=importlib.util.spec_from_file_location('extract',ROOT/'tools/audit/floor-measurement-sync-20261004/run.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
client=ROOT/'apps/ios/Rendprop/Networking/LiveAPIClient.swift';app=ROOT/'apps/ios/Rendprop/RendpropApp.swift';screen=ROOT/'apps/ios/Rendprop/Screens/NewListingView.swift'
a,b,c=client.read_text(),app.read_text(),screen.read_text();parent_template=ROOT/'tools/audit/listing-facts-sync-20261004/Fixture.swift.template';source=(Path(__file__).parent/'Fixture.swift.template').read_text().replace('__HARNESS__',parent_template.read_text().split('@main struct ListingFactsSyncChecks')[0])
cm={'CREATE':'    func createListing(_ listing: Listing)','UPDATE':'    func updateListing(_ listing: Listing)','UPDATE_MEASUREMENTS':'    func updateMeasurements(_ listing: Listing)','LISTING_BODY':'    private func listingBody(_ l: Listing,','MAP_LISTING':'    private func mapListing(_ dto: ListingDTO)','LISTING_DTO':'    private struct ListingDTO: Decodable','TOLERANT_MAP':'    struct TolerantStringMap: Decodable','DECODE':'    private func decode<T: Decodable>','PARSE_DATE':'    private static func parseDate(','ISO_STRING':'    private static func isoString(','WIRE_STATUS':'    private static func wireStatus(','LOCAL_STATUS':'    private static func localStatus('}
am={'IS_IN_WORKSPACE':'    func isInSelectedWorkspace(_ listing: Listing)', 'MODIFY':'    func modify(_ id: UUID,','SAVE_MEASUREMENTS':'    func saveMeasurements(_ plan: FloorMeasurementPlan,','RELOAD_SHARED':'    func reloadSharedMeasurements(_ id: UUID,','CONFIRM_LOCAL':'    func confirmLocalListingDetails(_ id: UUID)','FACTS_REVIEW_LOAD':'    func loadListingFactsReview(_ id: UUID)','FACTS_REVIEW_RESOLVE':'    func resolveListingFacts(_ review: ListingFactsReview,','SET_SOLD':'    func setSold(_ sold: Bool,','SET_PHOTO':'    func setMainPhoto(_ relPath:','SET_COORDINATE':'    func setCoordinate(lat:','MARK_DIRTY':'    func markDirty(_ id: UUID)','SYNC_LISTING':'    func syncListing(_ id: UUID)'}
sheet=c[c.index('struct ListingEditSheet: View'):];extracted={**{k:mod.block(a,m) for k,m in cm.items()},**{k:mod.block(b,m) for k,m in am.items()},'UNIT_ADDRESS':mod.block(c,'enum ListingUnitAddress'),'FORM':mod.block(c,'struct ListingFormData: Equatable'),'SHEET_INIT':mod.block(sheet,'    init(listing: Listing)'),'CAN_SAVE':mod.block(sheet,'    private var canSave:'),'SHEET_SAVE':mod.block(sheet,'    private func save()'),'REUSE_SAVE':mod.block(c,'    private func applyExistingEdits(')}
original={k:hashlib.sha256(v.encode()).hexdigest() for k,v in extracted.items()}
extracted['SHEET_INIT']=extracted['SHEET_INIT'].replace('init(listing: Listing) {','init(listing: Listing, model: SyncModel) {\n        self.model = model').replace('self._form = State(initialValue: data)','self.form = data')
if opts.inject_fault=='broad-form':
 needle='form.applyEdits(from: original, to: &$0)';assert extracted['SHEET_SAVE'].count(needle)==1;extracted['SHEET_SAVE']=extracted['SHEET_SAVE'].replace(needle,'form.apply(to: &$0)')
elif opts.inject_fault=='fresh-baseline':
 needle='expectedFacts: originalListing';assert extracted['SHEET_SAVE'].count(needle)==1;extracted['SHEET_SAVE']=extracted['SHEET_SAVE'].replace(needle,'expectedFacts: model.listings[0]')
elif opts.inject_fault=='price-rounding':
 needle='if listing.price.cents % 100 != 0 { priceDollars += String(format: ".%02d", listing.price.cents % 100) }';assert extracted['FORM'].count(needle)==1;extracted['FORM']=extracted['FORM'].replace(needle,'')
for k,v in extracted.items():source=source.replace('__'+k+'__',v)
assert not re.search(r'__[A-Z_]+__',source);fixture=OUT/'ActualListingFormIntent.swift';fixture.write_text(source)
models=[ROOT/('apps/ios/Rendprop/'+p) for p in ['Models/Listing.swift','Models/ListingClientContact.swift','Models/Money.swift','Networking/NativeReelDraft.swift','Auth/AnonymousAdoptionRecovery.swift','Auth/AdoptionLocalBindings.swift','Networking/WorkspaceSync.swift']]
files=[*models,client,app,screen,parent_template,Path(__file__).resolve(),Path(__file__).parent/'Fixture.swift.template'];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
receipt={'output':str(OUT),'fault':opts.inject_fault,'sourceHashes':{str(p.relative_to(ROOT)):sha(p) for p in files},'originalExtractedHashes':original,'extractedHashes':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in extracted.items()},'scope':'Actual form init/applyEdits and sheet init/save, AppModel.modify and intent sync; primitive UI and owned synthetic transport. Full iOS/SwiftUI build and real phone acceptance separate.','commands':[]}
frozen=[]
for path in models:
 saved=OUT/path.name;saved.write_bytes(path.read_bytes());frozen.append(saved)
expected={'broad-form':'Stale sheet stages only deliberately edited form fields','fresh-baseline':'Same-field save keeps the opened baseline rather than current remote facts','price-rounding':'Opened form preserves exact price cents'}.get(opts.inject_fault)
for name,args in [('compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,frozen),str(fixture),'-o',str(OUT/'checks')]),('run',[str(OUT/'checks')])]:
 p=subprocess.run(args,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90);log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'logSHA256':sha(log)});print(name,p.returncode,p.stdout[-3500:]);print('Evidence:',OUT)
 receipt['passed']=name=='run' and (p.returncode==1 and expected in p.stdout if expected else p.returncode==0)
 if name=='run' and p.returncode==0:receipt['assertions']=int(re.search(r'(\d+) assertions',p.stdout)[1])
 if expected:receipt['expectedRejection']=expected
 receipt['sourceBoundAtEnd']=all(sha(ROOT/k)==v for k,v in receipt['sourceHashes'].items());(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if (name=='compile' and p.returncode) or (name=='run' and not receipt['passed']):raise SystemExit(1)
assert receipt['sourceBoundAtEnd'], 'Source moved during native form gate'
