#!/usr/bin/env python3
"""Prepare an external diagnostic harness. Does not execute tests or a browser."""
import argparse
import hashlib
import shutil
import json
from pathlib import Path
import subprocess

TEMPLATES = Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def once(text, before, after):
    assert text.count(before) == 1, f'Diagnostic harness anchor changed: {before[:100]}'
    return text.replace(before, after)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--studio-root', required=True, type=Path)
    parser.add_argument('--base-dir', required=True, type=Path)
    args = parser.parse_args()
    STUDIO = args.studio_root.resolve(strict=True)
    SOURCE = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=STUDIO, text=True).strip()).resolve()
    assert STUDIO == SOURCE / 'apps/studio', 'Studio root must be the pinned shipping checkout apps/studio'
    pins = json.loads((TEMPLATES / 'shipping-inputs.json').read_text())
    EXPECTED_HEAD = pins['sourceCommit']
    assert EXPECTED_HEAD == '1c561d7b91d9b75bd7ba29aa081fcba959089fee', 'Payload shipping pin changed'
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip()
    assert head == EXPECTED_HEAD, 'Unexpected source commit'
    BASE = args.base_dir.resolve()
    assert BASE != TEMPLATES, 'Runtime copy must have a new base directory'
    assert SOURCE != BASE and SOURCE not in BASE.parents, 'Runtime copy must stay outside shipping checkout'
    for name, digest in pins['studioHashes'].items():
        assert sha(STUDIO / name) == digest, f'Shipping Studio input changed: {name}'
    for name, digest in pins['repositoryHashes'].items():
        assert sha(SOURCE / name) == digest, f'Shipping repository input changed: {name}'
    subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=SOURCE, check=True)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=False)
    for path in TEMPLATES.iterdir():
        if path.is_file() and path.suffix in ('.mjs', '.py', '.json', '.md'):
            shutil.copyfile(path, BASE / path.name)
    original = STUDIO / 'tests/cloud-editor-browser.mjs'
    text = original.read_text()
    text = once(text, 'const root = fileURLToPath(new URL("../", import.meta.url)),',
                f'const root = {json.dumps(str(STUDIO))},')
    for name in ['runner-facts', 'native-trace-observer', 'scheduling-probe', 'export-audio-output']:
        text = once(text, f'"./{name}.mjs"', json.dumps((STUDIO / f'tests/{name}.mjs').as_uri()))
    imports = ('import {passiveExportDiagnosticPlugin} from "./passive-export-plugin.mjs";\n'
               'import {installPassiveExportObserver} from "./passive-export-observer.mjs";\n')
    text = imports + text
    text = once(text, 'plugins:[exportRefusalReceiptPlugin]',
                'plugins:[passiveExportDiagnosticPlugin,exportRefusalReceiptPlugin]')
    text = once(text, 'await context.addInitScript(installMediaTimingFixture);',
                'await context.addInitScript(installMediaTimingFixture);\n'
                '    await context.addInitScript(installPassiveExportObserver);')
    capture = 'device.cadenceRefusals=await device.tab.evaluate(()=>window.exportCadenceRefusals??[]);'
    text = once(text, capture, capture + 'device.passiveCapture=await device.tab.evaluate(()=>window.rendpropPassiveExportDiagnostic?.snapshot()??null);')
    text = once(text,
        'timingDevices.map(({id,listing,trace,clockRefusals,cadenceRefusals,captureError})=>({id,listing,trace,clockRefusals,cadenceRefusals,captureError}))',
        'timingDevices.map(({id,listing,trace,clockRefusals,cadenceRefusals,passiveCapture,captureError})=>({id,listing,trace,clockRefusals,cadenceRefusals,passiveCapture,captureError}))')
    text = once(text, 'let browser, server, page;',
        'receipt.passiveDiagnosticCopy={testOnly:true,sourceHarnessSha256:' + json.dumps(sha(original)) +
        ',diagnosticModuleHashes:' + json.dumps({name: sha(BASE / name) for name in
        ['passive-export-plugin.mjs', 'passive-export-observer.mjs']}) +
        '};\nreceipt.loadAfterExportDiagnostics=[];\nreceipt.partialSuite=true;\n'
        'receipt.diagnosticScope="First narrated Studio export only, retaining existing H264/AAC, duration, narration PCM and dissolve/whip assertions. Later cloud-save/reconciliation/continuous-agent flows are not executed.";\n'
        'let browser, server, page;')
    verdict = '},{timeout:20000,message:"Narrated Studio MP4 export should become available or report its refusal"}).toMatch(/^(ready|refused)$/);'
    text = once(text, verdict, verdict + '\n  receipt.loadAfterExportDiagnostics.push({export:"narrated-studio",attempt:1,...quickLoad()});')
    refusal = '    receipt.firstExportRefusal={notice,cadence,runner:quickLoad()};'
    text = once(text, refusal, refusal + '\n'
        '    receipt.firstExportRefusal.downloadCount=await second.locator("a.rp-editor-download[download]").count();\n'
        '    assert.equal(receipt.firstExportRefusal.downloadCount,0,"A refused export must offer no download");')
    tail_start = '  await second.evaluate(() => window.cloudFixture.loseComplete());'
    catch_start = '} catch (error) { receipt.status = "failed";'
    assert text.count(tail_start) == 1 and text.count(catch_start) == 1
    at, until = text.index(tail_start), text.index(catch_start)
    assert at < until
    text = text[:at] + ('  assert.deepEqual(receipt.errors, []);\n'
        '  assert.deepEqual(receipt.externalRequests, []);\n'
        '  receipt.diagnosticCaseStatus="passed";\n'
        '  receipt.status="diagnostic-case-passed";\n') + text[until:]
    harness = BASE / 'cloud-editor-browser-diagnostic.mjs'
    harness.write_text(text)
    node_modules = BASE / 'node_modules'
    if node_modules.exists() or node_modules.is_symlink():
        assert node_modules.is_symlink() and node_modules.resolve() == (STUDIO / 'node_modules').resolve()
    else:
        node_modules.symlink_to(STUDIO / 'node_modules', target_is_directory=True)
    # Keep the shipping test's original assertion text, strict refusal and media
    # bounds in the copied harness. Only observation/root-resolution seams differ.
    pins = ['tests/cloud-editor-browser.mjs', 'tests/cloud-editor-fixture.tsx',
        'tests/runner-facts.mjs', 'tests/native-trace-observer.mjs', 'tests/scheduling-probe.mjs',
        'tests/export-audio-output.mjs', 'src/editor/export.ts', 'src/editor/recording-clock.ts',
        'src/editor/mp4-cadence.ts', 'src/editor/media.ts', 'src/editor/model.ts',
        'src/editor/overlay-renderer.ts', 'package-lock.json']
    module_names = ['vite', '@playwright/test', 'playwright', 'playwright-core']
    manifest = {'schema': 'rendprop-external-diagnostic-copy-v1', 'sourceCommit': head,
        'studioRoot': str(STUDIO), 'harness': str(harness),
        'sourceHashes': {name: sha(STUDIO / name) for name in pins},
        'repositoryHashes': json.loads((BASE / 'shipping-inputs.json').read_text())['repositoryHashes'],
        'repositoryRoot': str(SOURCE),
        'diagnosticHashes': {path.name: sha(path) for path in BASE.iterdir()
            if path.is_file() and path.suffix in ('.mjs', '.py', '.json')},
        'installedPackages': {name: json.loads((STUDIO / f'node_modules/{name}/package.json').read_text())['version']
            for name in module_names},
        'runtimeWarning': 'Partial diagnostic coverage, never a replacement mandatory CI result. Driver requires and records exact failing CI runtime versions.',
        'executed': False}
    (BASE / 'diagnostic-copy-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'prepared': True, 'testsExecuted': False, 'browserLaunched': False,
        'sourceCommit': head, 'harness': str(harness), 'manifest': str(BASE / 'diagnostic-copy-manifest.json')}))

if __name__ == '__main__':
    main()
