#!/usr/bin/env python3
"""Actual tab builder/routing and lead grouping/models; UI descriptors are closed."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-lead-inbox-'))
out.mkdir(parents=True, exist_ok=True)
paths = [root / p for p in [
    'apps/ios/Rendprop/RendpropApp.swift', 'apps/ios/Rendprop/Screens/SettingsView.swift',
    'apps/ios/Rendprop/Coach/CoachModel.swift', 'apps/ios/Rendprop/Networking/APIClient.swift',
    'apps/ios/Rendprop/Models/LeadInboxGrouping.swift', 'apps/ios/Rendprop/Models/Listing.swift',
    'apps/ios/Rendprop/Models/ListingClientContact.swift', 'apps/ios/Rendprop/Models/Money.swift',
    'apps/ios/Rendprop/Models/ProductionGuidance.swift', 'apps/ios/tests/LeadInboxGroupingTests.swift',
    'apps/ios/tests/run-lead-inbox-grouping.py']]
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start = hashes()
app, settings, coach, api, grouping = [p.read_text() for p in paths[:5]]

def block(source, anchor):
    begin = source.index(anchor)
    opening = source.index('{', begin)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

root_tabs = block(app, 'struct RootTabView:')
inbox = block(settings, 'struct LeadsView:')
assert 'NativeRootTab.destination(for: route)' in root_tabs
assert 'tabs.id(NativePresentationScope(actorID: workspaceAuth.userID,' in root_tabs
assert 'LeadInboxGrouping.current(leads, responseContext: loadedContext, currentContext: currentDeletionContext)' in inbox
assert 'LeadInboxGrouping.visibleListings(model.listings, canView: model.isInSelectedWorkspace)' in inbox
assert 'model.api.leads(listingServerID: listing?.serverID)' in inbox
assert 'auth.userID == actor, auth.syncSessionRevision == revision, WorkspaceContext.selectedOrgID == org' in inbox
assert 'loadRequest == request, !Task.isCancelled' in inbox
assert 'resetContext(); Task { await load() }' in inbox
assert 'case .leads: rootSheet = .leadsInbox' in block(app, 'private func drainIncomingRoutes()')

generated = '''import Foundation
enum FileStore { static func url(fromRelativePath p: String) -> URL { URL(fileURLWithPath: "/closed/" + p) } }
enum ProjectFeature { case tour, spatial, photos, photoStudio, reel, floorPlan, aerial }
protocol View {}
@propertyWrapper final class State<T> { var wrappedValue:T;var projectedValue:State<T>{self};init(wrappedValue:T){self.wrappedValue=wrappedValue} }
struct Label { let title:String;init(_ title:String,systemImage:String){self.title=title} }
struct TabEntry:View {
 var label:String="";var tag:Int = -1;var action:(()->Void)?
 func tabItem(_ content:()->Label)->TabEntry { var c=self;c.label=content().title;return c }
 func tag(_ tag:Int)->TabEntry { var c=self;c.tag=tag;return c }
}
@resultBuilder enum TabBuilder { static func buildBlock(_ values:TabEntry...)->[TabEntry]{values} }
struct TabView:View { let entries:[TabEntry];init(selection:State<Int>,@TabBuilder content:()->[TabEntry]){entries=content()} }
func NavigationStack(_ content:()->TabEntry)->TabEntry { content() }
func HomeDashboardView(goToListings:@escaping()->Void)->TabEntry { TabEntry(action:goToListings) }
func HomeListingsView()->TabEntry { TabEntry() }
func ProfileView()->TabEntry { TabEntry() }
func LeadsView()->TabEntry { TabEntry() }
func SettingsView()->TabEntry { TabEntry() }
'''
generated += block(coach, 'enum CoachRoute:') + '\n'
generated += block(app, 'enum NativeRootTab:') + '\n'
generated += block(api, 'struct Lead:') + '\n'
generated += block(inbox, 'private struct DeletionContext:').replace('private ', '', 1) + '\n'
generated += 'struct RootTabFixture { @State var tab = NativeRootTab.home.rawValue\n'
generated += block(root_tabs, 'private var tabs:').replace('private ', '', 1) + '\n}\n'
generated += grouping.replace('import Foundation', '') + '\n'
controls = [
    ('settings-renumbered', 'settings = 3, leads = 4', 'settings = 4, leads = 3', 'stable tags preserve existing profile and settings routes'),
    ('drop-listing-filter', 'return lead.listingID == id', 'return true', 'listing filter cannot mix another property inquiry'),
    ('foreign-listing-label', '!$0.isSample && canView($0)', '!$0.isSample', 'sample and foreign context labels stay unavailable'),
    ('sample-listing-label', '!$0.isSample && canView($0)', 'canView($0)', 'sample and foreign context labels stay unavailable'),
    ('stale-context-visible', 'responseContext == currentContext ? leads : []', 'leads', 'unbound response stays hidden'),
]
receipt = {'passed': False, 'sourceHashes': start, 'runs': [],
           'scope': 'Actual RootTabView tab builder, NativeRootTab routing, grouping helper, Lead model and private context compile. SwiftUI descriptors are closed; no UI, auth account, network, reply/send or deletion occurs.'}
for name, old, new, expected in [('actual', None, None, None)] + controls:
    source = generated if old is None else generated.replace(old, new)
    if old is not None: assert source != generated
    target = out / (name + '.swift'); target.write_text(source)
    binary = out / name
    compile_run = subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                                 *map(str, paths[5:9]), str(target), str(paths[9]), '-o', str(binary)], capture_output=True, text=True)
    (out / (name + '-compile.log')).write_text(compile_run.stdout + compile_run.stderr)
    assert compile_run.returncode == 0, (name, compile_run.stderr[-4000:])
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    log = run.stdout + run.stderr; (out / (name + '.log')).write_text(log)
    if expected: assert run.returncode != 0 and 'FAILED: ' + expected in log, (name, log[-4000:])
    else: assert run.returncode == 0, log[-4000:]
    receipt['runs'].append({'name': name, 'exit': run.returncode, 'expectedFailure': expected,
                            'generatedSourceSHA256': hashlib.sha256(source.encode()).hexdigest()})
receipt['sourceHashesAtEnd'] = hashes()
assert receipt['sourceHashesAtEnd'] == start
receipt['passed'] = True
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps({'passed': True, 'runs': len(receipt['runs']), 'receipt': str(out / 'receipt.json')}))
