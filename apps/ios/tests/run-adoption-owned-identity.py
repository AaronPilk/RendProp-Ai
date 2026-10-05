#!/usr/bin/env python3
"""Compile actual adoption + paid marker bodies against isolated preferences/files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / 'apps/ios/Rendprop'

def block(source, anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor)
    pos = source.index('{', start)
    depth = 1
    end = pos + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    out = args.out or Path(tempfile.mkdtemp(prefix='rendprop-adoption-owned-', dir=os.environ.get('RUNNER_TEMP')))
    out.mkdir(parents=True, exist_ok=True)
    models = [IOS / p for p in ['Models/Listing.swift', 'Models/ListingClientContact.swift', 'Models/Money.swift',
              'Models/ProductionGuidance.swift', 'Networking/ProductionPlan.swift', 'Auth/AnonymousAdoptionRecovery.swift',
              'Auth/AdoptionLocalBindings.swift']]
    library = IOS / 'Auth/AdoptionProductionLibrary.swift'
    fly = IOS / 'Screens/FlythroughDetailView.swift'
    api = IOS / 'Networking/APIClient.swift'
    fixture = ROOT / 'apps/ios/tests/AdoptionOwnedIdentityTests.swift'
    editor_fixture = ROOT / 'apps/ios/tests/AdoptionArchiveEditorTests.swift.template'
    settings = IOS / 'Screens/SettingsView.swift'
    sync = IOS / 'Networking/WorkspaceSync.swift'
    inputs = models + [library, fly, api, fixture, editor_fixture, settings, sync, Path(__file__).resolve(), IOS / 'RendpropApp.swift', IOS / 'Auth/AuthStore.swift']
    def hashes(): return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    receipt = {'passed': False, 'start_source_sha256': hashes(), 'runs': [], 'limitations': [
        'Actual adoption/profile/paid marker Foundation bodies execute against synthetic files and isolated preferences.',
        'Actual helper/editor/Listing UserDefaults dependencies are mechanically redirected to the isolated fixture domain; the card API and prepared UIImage byte writer are closed boundaries.',
        'No real user, camera, provider request, Apple call, purchase or network. Portrait bytes are synthetic, not visual acceptance.',
        'Archive Review and explicit Save actions execute with a closed card API and image-byte boundary; Photos picker, camera and visual acceptance are not claimed.']}
    try:
        actual = library.read_text()
        pending = block(fly.read_text(), 'private struct PendingReelRequest: Codable, Sendable').replace('private struct', 'struct', 1)
        pending = pending.replace('UserDefaults.standard', 'FixturePreferences.defaults')
        generated = '\nimport Foundation\nimport CryptoKit\n' + block(api.read_text(), 'struct AIVideoJob: Codable, Sendable') + '\n' + pending
        generated_path = out / 'ActualPendingRequest.swift'
        generated_path.write_text(generated)
        card_source = settings.read_text()
        card = card_source[card_source.index('struct AgentCard {'):card_source.index('    static let fieldNames', card_source.index('struct AgentCard {'))]
        card += card_source[card_source.index('    static let fieldNames'):card_source.index('\n', card_source.index('    static let fieldNames'))] + '\n'
        for anchor in ['    static var personalPrefix:', '    static var personalReadVersion:', '    static var primaryTypeKey:', '    static func migrateLegacyIfNeeded', '    static func key(_ field: String, for type:', '    static func card(for type:', '    static var current: AgentCard', '    var brandFields:', '    var instagramURL:', '    var tiktokURL:', '    var linkedinURL:', '    private static func socialURL', '    private static func looksLikeHost', '    var websiteURL:', '    static func headshotURL(for type:']:
            card += block(card_source,anchor) + '\n'
        card += 'static func saveHeadshot(_ image: UIImage) { try! image.bytes.write(to:headshotURL(for:SpaceType.current),options:.atomic) }\n}\n'
        policies = '\n'.join(block(card_source,a).replace('private ', '', 1) for a in ['private enum PersonalCardError', 'private struct PersonalCardDraft', 'private enum PersonalCardStore', 'private struct ProfileShareContext'])
        editor = editor_fixture.read_text()
        bodies = '\n'.join(block(card_source,a).replace('private ', '', 1) for a in ['    private var primaryType:', '    private var isPrimary:', '    private var detailFields:', '    private var contextIsCurrent:', '    @MainActor private func reviewSavedDetails', '    @MainActor private func saveDetails', '    @MainActor private func finishArchiveReview'])
        picker = '                    AgentCard.saveHeadshot(img)\n                    archivePortraitIsSelected = false'
        assert card_source.count(picker) == 1
        bodies += '\nfunc choosePreparedPortrait(_ img: UIImage) {\n' + picker + '\n}\n'
        editor = editor.replace('// END EDITOR SUPPORT', bodies + '\n// END EDITOR SUPPORT')
        actual_editor = ('import Foundation\nimport CryptoKit\n' + block(sync.read_text(),'struct PersonalCardReceipt: Codable, Equatable, Sendable') + '\n' + block(sync.read_text(),'enum CloudSyncError: LocalizedError') + '\n' + card + policies + '\n' + editor).replace('UserDefaults.standard','FixturePreferences.defaults').replace('= .standard','= FixturePreferences.defaults')
        editor_path = out / 'ActualArchiveEditor.swift'
        editor_path.write_text(actual_editor)
        listing_path = out / 'ActualListing.swift'
        listing_path.write_text(models[0].read_text().replace('UserDefaults.standard','FixturePreferences.defaults'))
        compile_models = [listing_path] + models[1:]
        variants = [
            ('actual', actual, None),
            ('negative-cloud-card', actual.replace('let allowCard = dispositionAllows && mayActivate(journal, destinationCard: verifiedDestinationCard,\n            destinationType: verifiedDestinationType, verified: destinationCardWasVerified)', 'let allowCard = true'), 'Guest local absence cannot overwrite newer-cloud'),
            ('negative-destination-local', actual.replace('if card.destinationWasOccupied { continue }', '// existing recipient whole-card fence omitted').replace('guard textStillMatches, portraitStillMatches else { continue }','// current partial-recipient fence omitted'), 'Guest contact fields are not mixed into existing recipient card'),
            ('negative-paid-copy', actual.replace('for pending in journal.paidRequests where survivingIDs.contains(pending.listingID)', 'for pending in journal.paidRequests where false'), 'Adopted paid receipt becomes review-only and blocks generation'),
            ('negative-retired-replay', actual.replace('if journal.completed { return }', '// completed receipt replay fence omitted'), 'Receipt replay never revives deliberately retired paid marker'),
            ('negative-owner', actual.replace('activeOwner == binding.destinationUserID else', 'true else'), 'Another account cannot claim a verified adoption'),
            ('negative-unselected', actual.replace('return targets.sorted { $0.path < $1.path }', 'return []'), 'Unselected named workspace cannot evade adopted paid marker'),
            ('negative-unreadable-fallback', actual.replace('bytes = try regularData(file, maximum: 24_000)', 'bytes = (try? regularData(file, maximum: 24_000)).flatMap { value in (try? JSONSerialization.jsonObject(with: value)) == nil ? nil : value } ?? legacy'), 'Unreadable authoritative guest marker blocks new paid POST without legacy fallback'),
            ('negative-legacy-wrong-type', actual.replace('} else if legacyIsOccupied {','} else if legacyIsOccupied && legacy != nil {'), 'Wrong-type guest marker transfers an opaque blocker without provider permission'),
            ('negative-partial-whole-card', actual.replace('guard textStillMatches, portraitStillMatches else { continue }','// newer recipient whole-card fence omitted'), 'Newer named whole identity cannot mix with guest fields: newer-name'),

        ]
        consumer_control = generated.replace('FixturePreferences.defaults.object(forKey: key(context)) != nil','FixturePreferences.defaults.data(forKey: key(context)) != nil')
        assert consumer_control != generated
        variants.append(('negative-legacy-consumer',actual,'Wrong-type legacy marker blocks the actual new paid POST consumer'))
        editor_controls = {
            'negative-editor-portrait-choice': (actual_editor.replace('AgentCard.saveHeadshot(img)\n                    archivePortraitIsSelected = false','AgentCard.saveHeadshot(img)\n                    // newer explicit portrait provenance omitted'), 'Review then choose then Save preserves the newer portrait'),
            'negative-editor-primary': (actual_editor.replace('            primaryTypeRaw = receipt.spaceType ?? ""','            // fresh named primary industry omitted'), 'Archive Review refreshes the named hosted industry before Save'),
            'negative-editor-late-context': (actual_editor.replace('guard contextIsCurrent, detailFields == before, AgentCard.personalReadVersion == version,','guard detailFields == before, AgentCard.personalReadVersion == version,'), 'Held Review rejects changed context without activation or POST: session'),
            'negative-editor-typed': (actual_editor.replace('guard contextIsCurrent, detailFields == before, AgentCard.personalReadVersion == version,','guard contextIsCurrent, AgentCard.personalReadVersion == version,'), 'Held Review rejects changed context without activation or POST: typed'),
            'negative-editor-owner-receipt': (actual_editor.replace('            _ = try receipt.checked(owner: owner)','            // named receipt owner verification omitted'), 'Held Review rejects changed context without activation or POST: wrong-receipt'),
            'negative-editor-early-retirement': (actual_editor.replace('let draft = try PersonalCardStore.stage(fields, type: editingType, expected: baseline)','let draft = try PersonalCardStore.stage(fields, type: editingType, expected: baseline)\n            try finishArchiveReview(owner: owner)'), 'Failed Save retains archive review and portrait provenance for retry'),
        }
        for name,(editor_source,expected) in editor_controls.items():
            assert editor_source != actual_editor, name + ' missing actual editor mutation anchor'
            variants.append((name,actual,expected))
        for name, source, expected in variants:
            editor_path.write_text(editor_controls.get(name,(actual_editor,None))[0])
            generated_path.write_text(consumer_control if name == 'negative-legacy-consumer' else generated)
            assert expected is None or name in editor_controls or name == 'negative-legacy-consumer' or source != actual, name + ' missing mutation anchor'
            runtime = out / (name + '.swift')
            runtime.write_text(source.replace('= .standard','= FixturePreferences.defaults'))
            binary = out / name
            compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                *map(str, compile_models), str(runtime), str(generated_path), str(editor_path), str(fixture), '-o', str(binary)],
                text=True, capture_output=True, timeout=90)
            (out / (name + '-compile.log')).write_text(compile_result.stdout + compile_result.stderr)
            assert compile_result.returncode == 0, name + ': ' + compile_result.stderr
            data = out / (name + '-data')
            data.mkdir()
            run = subprocess.run([str(binary), str(data)], text=True, capture_output=True, timeout=45)
            log = run.stdout + run.stderr
            (out / (name + '.log')).write_text(log)
            correct = run.returncode == 0 if expected is None else run.returncode != 0 and any(prefix + expected in log for prefix in ['Precondition failed: ', 'Fatal error: '])
            receipt['runs'].append({'name': name, 'compile_exit_code': compile_result.returncode,
                'exit_code':run.returncode, 'expected_failure':expected, 'expected_result':correct, 'output':log[:1000]})
            binary.unlink()
            assert correct, name + ': ' + log
        receipt['passed'] = True
    except BaseException as error:
        receipt['failure'] = str(error)
        raise
    finally:
        receipt['end_source_sha256'] = hashes()
        receipt['source_unchanged'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
        receipt['passed'] = receipt['passed'] and receipt['source_unchanged']
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
        print('Adoption identity evidence:', out)
    assert receipt['passed']
    print('PASS: actual guest profile + paid-marker adoption; 16 compiled semantic fault controls')

if __name__ == '__main__': main()
