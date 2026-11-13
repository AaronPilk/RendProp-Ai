#!/usr/bin/env python3
"""Source-bound room Done and location/address commit proof, no UI or network."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-form-commit-'))
out.mkdir(parents=True, exist_ok=True)
room = root/'apps/ios/Rendprop/Screens/ReviewSubmitView.swift'
location = root/'apps/ios/Rendprop/Screens/NewListingView.swift'
tag = root/'apps/ios/Rendprop/Models/RoomTag.swift'
fixture = root/'apps/ios/tests/NativeFormCommitTests.swift'
paths = [room, location, tag, fixture, Path(__file__).resolve()]
hashes = lambda: {str(x.relative_to(root)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before = hashes()

def block(source, anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor); opening = source.index('{', start); depth = 1; end = opening+1
    while depth:
        depth += (source[end] == '{')-(source[end] == '}'); end += 1
    return source[start:end]

r, n = room.read_text(), location.read_text()
assert 'Button("Done", action: finishTagging)' in r
assert '.onChange(of: form.address) { addressDidChange($0) }' in n
assert n.count('applyLocationSuggestion(') == 3, 'Real callback and existing simulator fixture must use the same binding'
room_methods = '\n'.join(block(r, x).replace('private ', '') for x in ['    private func finishTagging(', '    private func addCustomTag(', '    private func addTag(', '    private func discardUnconfirmedAITags('])
location_methods = '\n'.join(block(n, x).replace('private ', '') for x in ['    private func applyLocationSuggestion(', '    private func addressDidChange(', '    private func cancelCurrentLocation('])
body = 'import Foundation\n'+tag.read_text()+'\n'+block(n, 'enum ListingUnitAddress {')+'\n'
body += '''
final class RoomCommitHarness {
var tags:[RoomTag]=[];var customName="";var customNameFocused=false;var current=0.0;var dismissedTags:[RoomTag]?
func dismiss(){dismissedTags=tags}
'''+room_methods+'\n}\n'
body += 'struct ClosedForm { var address="",unit="";var isRealEstate=true\n'+block(n, '    mutating func setSuggestedAddress(')+'\n}\n'
body += '''
final class LocationCommitHarness {
var form=ClosedForm();var pendingCoord:CLLocationCoordinate2D?;var pendingCoordAddress:String?
var locationRequestID:UUID?;var locating=false;let locator=ClosedLocator();var locationGeocoder:ClosedGeocoder?
'''+location_methods+'\n}\n'
variants = [('actual', body, None),
    ('negative-done-loses-name', body.replace('        addCustomTag()\n', '        // omitted custom commit\n'), 'Done commits the typed custom name before host dismissal'),
    ('negative-dismiss-before-commit', body.replace('        addCustomTag()\n', '        dismiss()\n        addCustomTag()\n').replace('        discardUnconfirmedAITags()\n        dismiss()', '        discardUnconfirmedAITags()'), 'Done commits the typed custom name before host dismissal'),
    ('negative-unconfirmed-ai-leaks', body.replace('        discardUnconfirmedAITags()\n', '        // omitted unconfirmed suggestion cleanup\n'), 'Done commits the typed custom name before host dismissal'),
    ('negative-retain-stale-coordinate', body.replace('        pendingCoord = nil\n', '        // omitted prior property coordinate reset\n'), 'Manual address changes discard the prior property\'s coordinate'),
    ('negative-lose-generated-coordinate', body.replace('        pendingCoordAddress = form.address', '        pendingCoordAddress = nil'), 'The location-generated address keeps its own coordinate'),
    ('negative-location-lookup-race', body.replace('        if locationRequestID != nil { cancelCurrentLocation() }', '        // omitted lookup invalidation'), 'Manual address changes cancel an in-flight location lookup')]
receipt = {'passed':False, 'start_source_sha256':before, 'runs':[], 'limitations':['Actual commit methods and RoomTag/ListingUnitAddress execute with closed sheet dismissal, form/location/geocoder boundaries. No SwiftUI UI lifecycle, Maps request, phone or production proof.']}
try:
    for name, code, reason in variants:
        assert reason is None or code != body, name+' missing mutation anchor'
        src, binary = out/(name+'.swift'), out/name; src.write_text(code)
        c = subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(src),str(fixture),'-o',str(binary)],capture_output=True,text=True,timeout=120)
        (out/(name+'-compile.log')).write_text(c.stdout+c.stderr)
        assert c.returncode == 0, name+' compile failed: '+c.stderr
        run = subprocess.run([str(binary)],capture_output=True,text=True,timeout=20); log = run.stdout+run.stderr
        (out/(name+'.log')).write_text(log)
        accepted = run.returncode == 0 if reason is None else run.returncode != 0 and 'Precondition failed: '+reason in log
        receipt['runs'].append({'name':name,'exit_code':run.returncode,'expected_failure':reason,'expected_result':accepted,'output':log[:2500]})
        assert accepted, name+': '+log
except BaseException as e:
    receipt['failure'] = str(e); raise
finally:
    receipt['end_source_sha256']=hashes(); receipt['source_binding_matches']=before==receipt['end_source_sha256']
    receipt['passed']='failure' not in receipt and len(receipt['runs'])==len(variants) and receipt['source_binding_matches']
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(receipt['runs'][0]['output']); print(f'PASS: {len(variants)-1} compiled negative controls; receipt: {out / "receipt.json"}')
