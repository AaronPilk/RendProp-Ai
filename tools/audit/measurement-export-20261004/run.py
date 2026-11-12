#!/usr/bin/env python3
"""Compile actual export admission, provenance, PDF text loops and scan hull.

Only renderer/text-drawing/file output boundaries are inert; no native render is
claimed. Native UI/PDF layout verification is separate. Models are production.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[3]
EDITOR = ROOT / 'apps/ios/Rendprop/Screens/FloorMeasurementsView.swift'
WORKSHEET = ROOT / 'apps/ios/Rendprop/Screens/FloorMeasurementWorksheetView.swift'
DETAIL = ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'

def block(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker); opening = source.index('{', start); depth = 1; end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--inject-fault', choices=['ignore-geometry', 'ignore-conflict', 'ignore-facts-review', 'phone-as-manual', 'omit-room-records', 'nonstandard-paper', 'omit-page-transform', 'omit-phone-limitation', 'ignore-media-actor', 'ignore-media-revision', 'ignore-media-workspace'])
    args = p.parse_args()
    source = {q: q.read_text() for q in [EDITOR, WORKSHEET, DETAIL]}
    safety = block(source[EDITOR], 'enum FloorMeasurementExportSafety {')
    provenance = block(source[WORKSHEET], 'enum FloorMeasurementProvenance {')
    pdf = block(source[WORKSHEET], '        try pdf.writePDF(to: url)')
    layout = block(source[WORKSHEET], 'enum FloorMeasurementPDFLayout {')
    constructor = 'let pdf = UIGraphicsPDFRenderer(bounds: FloorMeasurementPDFLayout.pageBounds)'
    assert source[WORKSHEET].count(constructor) == 1
    if args.inject_fault == 'ignore-geometry':
        assert safety.count('return saved == expected') == 1
        safety = safety.replace('return saved == expected', 'return true')
    elif args.inject_fault == 'ignore-conflict':
        assert safety.count('current.measurementSync?.conflict != true,') == 1
        safety = safety.replace('current.measurementSync?.conflict != true,', 'true,')
    elif args.inject_fault == 'ignore-facts-review':
        assert safety.count('current.measurementSync?.factsReviewRequired != true,') == 1
        safety = safety.replace('current.measurementSync?.factsReviewRequired != true,', 'true,')
    elif args.inject_fault == 'phone-as-manual':
        before = 'source == .phoneEstimate ? "Phone estimate — verify" : "Entered dimensions — verify"'
        assert provenance.count(before) == 1
        provenance = provenance.replace(before, '"Entered dimensions — verify"')
    elif args.inject_fault == 'omit-room-records':
        before = 'let floorRooms = plan.rooms.filter { $0.floor == value }'
        assert pdf.count(before) == 1
        pdf = pdf.replace(before, 'let floorRooms: [FloorMeasurementRoom] = []')
    elif args.inject_fault == 'nonstandard-paper':
        before = 'width: 792, height: 612'
        assert layout.count(before) == 1
        layout = layout.replace(before, 'width: 842, height: 632')
    elif args.inject_fault == 'omit-page-transform':
        before = 'context.cgContext.concatenate(contentTransform)'
        assert layout.count(before) == 1
        layout = layout.replace(before, '_ = contentTransform')
    elif args.inject_fault == 'omit-phone-limitation':
        before = 'return hasPhoneData ? phoneRulerLimitation : nil'
        assert provenance.count(before) == 1
        provenance = provenance.replace(before, 'return nil')
    # Bind UI wiring and legacy labeling as well as the executable helper.
    assert 'canExport: { isFresh(item.plan) && isFresh(plan) }' in source[EDITOR]
    assert 'MeasurementExport(image: result.image, pdfURL: result.pdfURL, plan: plan)' in source[EDITOR]
    assert 'measurements.export").disabled(!isFresh(plan))' in source[EDITOR]
    assert 'Scan hull estimate ≈' in source[DETAIL]
    assert 'schematic, not to scale; not a survey. Hull area' in source[DETAIL]
    # Verify both PNG construction paths call the same conditional production note.
    selected_image = block(source[WORKSHEET], '        let content = VStack(')
    other_image = block(source[WORKSHEET], '            let drawing = VStack(')
    assert 'phoneNote(plan: plan, floor: floor)' in selected_image
    assert 'phoneNote(plan: plan, floor: value)' in other_image
    assert 'Text(phoneNote)' in selected_image and 'Text(phoneNote)' in other_image
    template = Path(__file__).with_name('Fixture.swift.template').read_text()
    replacements = {'__SAFETY__': safety, '__PROVENANCE__': provenance,
        '__FORMAT__': block(source[WORKSHEET], 'enum FloorMeasurementFormat {'),
        '__PDF_WRITE__': pdf, '__PDF_LAYOUT__': layout, '__PDF_CONSTRUCTOR__': constructor,
        '__DRAW_TEXT__': block(source[WORKSHEET], '    private static func drawText('),
        '__HULL__': block(source[DETAIL], '    private static func footprintArea(')}
    for key, value in replacements.items():
        assert template.count(key) == 1, key
        template = template.replace(key, value)
    out = Path(tempfile.mkdtemp(prefix='rendprop-measurement-export-', dir='/tmp'))
    fixture = out / 'ActualMeasurementExport.swift'; fixture.write_text(template)
    model_paths = ['Models/Listing.swift', 'Models/ListingClientContact.swift', 'Models/Money.swift',
        'Networking/NativeReelDraft.swift', 'Auth/AnonymousAdoptionRecovery.swift',
        'Auth/AdoptionLocalBindings.swift', 'Networking/WorkspaceSync.swift']
    models = [ROOT / 'apps/ios/Rendprop' / value for value in model_paths]
    source.update({q: q.read_text() for q in models})
    wire = models[-1]
    actual_context = block(source[wire], 'struct CloudMediaAccessContext:')
    compiled_context = actual_context
    context_faults = {
        'ignore-media-actor': 'AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == actorID',
        'ignore-media-revision': 'AuthStore.shared.syncSessionRevision == revision',
        'ignore-media-workspace': 'WorkspaceContext.selectedOrgID == (selectedLibraryID ?? orgID) else',
    }
    if args.inject_fault in context_faults:
        before = context_faults[args.inject_fault]
        assert actual_context.count(before) == 1
        after = 'true else' if args.inject_fault == 'ignore-media-workspace' else 'true'
        compiled_context = actual_context.replace(before, after)
        modified_wire = out / 'ActualWorkspaceSync.swift'
        assert source[wire].count(actual_context) == 1
        modified_wire.write_text(source[wire].replace(actual_context, compiled_context))
        models = [*models[:-1], modified_wire]
    compile_result = subprocess.run(['xcrun','swiftc','-parse-as-library',*[str(q) for q in models],str(fixture),'-o',str(out/'checks')],text=True,capture_output=True)
    (out/'compile.log').write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        print(compile_result.stdout + compile_result.stderr); raise SystemExit(compile_result.returncode)
    result = subprocess.run([str(out/'checks')],text=True,capture_output=True)
    (out/'run.log').write_text(result.stdout + result.stderr)
    receipt = {'status':result.returncode,'injectedFault':args.inject_fault,'nativeRender':False,
        'networkCalls':0,'cameraCalls':0,'customerFilesAccessed':0,'productionMutations':0,
        'actualMediaContextSha256':hashlib.sha256(actual_context.encode()).hexdigest(),
        'compiledMediaContextSha256':hashlib.sha256(compiled_context.encode()).hexdigest(),
        'sourceHashes':{str(q.relative_to(ROOT)):hashlib.sha256(s.encode()).hexdigest() for q,s in source.items()}}
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(result.stdout + result.stderr,end=''); print('Artifacts: '+str(out)); raise SystemExit(result.returncode)
if __name__ == '__main__': main()
