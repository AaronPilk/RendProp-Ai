#!/usr/bin/env python3
"""Actual pinned API methods and editor/inbox consumers; closed HTTP and save boundaries."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
out=a.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-native-lead-privacy-'));out.mkdir(parents=True,exist_ok=True)
names=['Models/Listing.swift','Models/ListingClientContact.swift','Models/Money.swift','Models/ProductionGuidance.swift','Networking/APIClient.swift','Networking/LiveAPIClient.swift','Screens/ClientContactView.swift','Screens/SettingsView.swift']
paths=[root/'apps/ios/Rendprop'/n for n in names]+[Path(__file__).resolve(),root/'apps/ios/tests/NativeLeadPrivacyTests.swift']
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start=hashes();src={n:p.read_text() for n,p in zip(names,paths)}
def block(s,a):
    begin=s.index(a);opening=s.index('{',begin);depth=1;end=opening+1
    while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[begin:end]
editor=src['Screens/ClientContactView.swift'];inbox=src['Screens/SettingsView.swift']
assert 'Task { await verifyRecipient() }' in editor and 'clientContact.verifyRecipient' in editor
assert 'Task { await deleteSavedLead(lead, expected: expected) }' in inbox and 'allowsFullSwipe: false' in inbox
assert 'if closeAfterSave { dismiss() }' in block(editor,'private func save(closeAfterSave:')
actual='''import Foundation
enum FileStore { static func url(fromRelativePath p:String)->URL { URL(fileURLWithPath:"/closed/"+p) } }
@MainActor final class AuthStore { static let shared=AuthStore();var userID:String?;var syncSessionRevision:UInt64=1 }
enum WorkspaceContext { static var selectedOrgID:UUID? }
enum UserFacingError { static func message(_ error:Error,fallback:String)->String { fallback } }
'''
for anchor in ['struct LeadDeletionReceipt:','struct ClientRecipientVerificationReceipt:','struct Lead:']:
    actual+=block(src['Networking/APIClient.swift'],anchor)+'\n'
actual+='''@MainActor final class WireFixture {
 var response=Data();var requests:[URLRequest]=[];var wait=false;var waiter:CheckedContinuation<Void,Never>?
 func url(_ p:[String])->URL { URL(string:"https://closed.invalid/"+p.joined(separator:"/"))! }
 func makeRequest(url:URL,method:String="GET",json:[String:Any]?=nil)->URLRequest { var r=URLRequest(url:url);r.httpMethod=method;r.httpBody=json.flatMap { try? JSONSerialization.data(withJSONObject:$0) };return r }
 func execute(_ request:URLRequest) async throws ->Data { requests.append(request);if wait { await withCheckedContinuation { waiter=$0 } };return response }
 func resume() { wait=false;waiter?.resume();waiter=nil }
 func decodeExact<T:Decodable>(_ data:Data)throws->T { try JSONDecoder().decode(T.self,from:data) }
'''
for anchor in ['func requestClientRecipientVerification(', 'func deleteLead(']:
    actual+=block(src['Networking/LiveAPIClient.swift'],anchor)+'\n'
actual+='''}
@MainActor final class ModelFixture {
 let api=WireFixture();var listings:[Listing];var saved=0
 init(listingID:UUID,org:UUID) { var l=Listing(id:listingID,address:"Synthetic",beds:0,baths:0,sqft:0,price:Money(cents:0));l.serverID=listingID;l.serverOrgID=org;listings=[l] }
 func refreshClientContact(for id:UUID) async throws {}
}
@MainActor final class EditorFixture {
 let model:ModelFixture;let listing:Listing;var contact:ListingClientContact
 var verifyingRecipient=false;var verificationRequested=false;var error:String?;var contextInvalidated=false;var saveFailure=false
'''
for anchor in ['private struct Context:', 'private var current:', 'private var live:', 'private var hasFreshContext:']:
    actual+=block(editor,anchor).replace('private ','',1)+'\n'
actual+='''var context:Context?
 init(model:ModelFixture,contact:ListingClientContact) { self.model=model;listing=model.listings[0];self.contact=contact;context=current }
 func save(closeAfterSave:Bool=true) async {
  if saveFailure { error="Synthetic save rejected";return }
  model.saved+=1;contact.recipientVerifiedEmail=nil;contact.recipientVerifiedAt=nil
  model.listings[0].clientContact=contact;model.listings[0].clientContactDirty=false;error=nil
 }
'''
actual+=block(editor,'private func verifyRecipient()').replace('private ','',1)+'\n}\n'
actual+='''@MainActor final class InboxFixture {
 let model:ModelFixture;let auth=AuthStore.shared;var leads:[Lead];var deletingIDs=Set<UUID>();var errorMessage:String?
 init(model:ModelFixture,leads:[Lead]) { self.model=model;self.leads=leads }
'''
for anchor in ['private struct DeletionContext:', 'private var currentDeletionContext:', 'private func deleteSavedLead(']:
    actual+=block(inbox,anchor).replace('private ','',1)+'\n'
actual+='}\n'
controls=[
 ('false-verification-authority','== recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()','== verified.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()','changed recipient invalidates previous verification','Models/ListingClientContact.swift'),
 ('ignore-save-failure','current == expected, error == nil','current == expected, true','failed contact save prevents verification request',None),
 ('unconfirmed-delete','guard ok, deleted, leadID == expected','guard ok, deleted, true','wrong-lead receipt cannot erase cached inquiry',None),
 ('drop-delete-context','currentDeletionContext == expected','true','stale confirmation cannot delete in another workspace',None)]
receipt={'passed':False,'start_source_sha256':start,'runs':[],'limitations':['Actual API request/receipt and editor/inbox consumer bodies compile; HTTP, client save and contact refresh are closed doubles.','No verification email, customer data, live API or real deletion.']}
library=paths[:4]
for name,old,new,expected,library_name in [('actual',None,None,None,None)]+controls:
    generated=actual if old is None or library_name else actual.replace(old,new)
    libraries=library
    if library_name:
        target=out/(name+'-model.swift');original=src[library_name];mutated=original.replace(old,new);assert mutated!=original;target.write_text(mutated)
        libraries=[target if str(p).endswith(library_name) else p for p in library]
    elif old:assert generated!=actual
    target=out/(name+'.swift');target.write_text(generated);binary=out/name
    c=subprocess.run(['xcrun','swiftc','-parse-as-library',*map(str,libraries),str(target),str(paths[-1]),'-o',str(binary)],capture_output=True,text=True)
    (out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,(name,c.stderr[-3000:])
    run=subprocess.run([str(binary)],capture_output=True,text=True);log=run.stdout+run.stderr;(out/(name+'.log')).write_text(log)
    if expected:assert run.returncode!=0 and 'FAILED: '+expected in log,(name,log[-3000:])
    else:assert run.returncode==0,log[-3000:]
    receipt['runs'].append({'name':name,'exit':run.returncode,'expected_fault':expected,'generated_sha256':hashlib.sha256(generated.encode()).hexdigest(),'log':str(out/(name+'.log'))})
receipt['end_source_sha256']=hashes();assert receipt['end_source_sha256']==start
receipt['passed']=True;(out/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'passed':True,'receipt':str(out/'receipt.json'),'runs':len(receipt['runs'])}))
