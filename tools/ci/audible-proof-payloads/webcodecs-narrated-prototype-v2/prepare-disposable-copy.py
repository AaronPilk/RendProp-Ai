#!/usr/bin/env python3
"""Prepare the first narrated WebCodecs proof in a disposable 1c checkout.

No checkout is altered until every pinned shipping input and the separately
installed Mediabunny dependency has been verified. This script is preparation
only; it does not install packages, build, launch a browser, or run a test.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SHIPPING_SHA = "1c561d7b91d9b75bd7ba29aa081fcba959089fee"
EXPECTED_INTEGRITY = "sha512-goZpibvo/5hkc/56WVNm93Ini+o7K4y8aXA20c/BN1B+m3L5aHQa8MTvO+S1APg/YI8kMILtrX6QCqUtxLW7bA=="
EXPECTED_ENTRY_SHA256 = "9236aa229772332a4f5ed04e453d8794a84311468012a9dd0de78e35301d39c0"
EXPECTED_LOCK_SHA256 = "8877584e305eacab211161e8eb8564cbfcf32ef14c23864cbd5a61794020061b"
EXPECTED_TREE_SHA256 = "b68f9bb6b4ffb438935e12e684c7b1a989d1ad592afef166ad1ef1d1792ebe64"
PINNED = {
    "apps/studio/src/editor/VideoEditor.tsx": "7c81da9c26c1e28937fada17e034c3f07145a16ef7606c5ca476e64e33bed5ff",
    "apps/studio/src/editor/export.ts": "730ee8ede72ce76df7d47cd40f12c134731dbda330b6f92c50a8d080880bd04a",
    "apps/studio/src/editor/media.ts": "82353070aaa85733ad89583fc52dedef36a9296cd6e4f594910571e7597b939b",
    "apps/studio/src/editor/model.ts": "9696653581899e097d0b0e8ce395c9c80d5e6f264cd8f17411a6ff5545dfa8dd",
    "apps/studio/src/editor/overlay-renderer.ts": "a926d2621fc31e2753859c7c7fd66be019a93262cb34c8973126b11cf9ae8832",
    "apps/studio/src/editor/mp4-cadence.ts": "fb2bdb8e54a2e7698528f6fd9c0a440fc8698e28af2cebe96bbea2834bb1a852",
    "apps/studio/src/editor/recording-clock.ts": "4b3ecc66ba7ec1acf874190ee18d7f7d44b409b99e80504f10fa5d0ff77102df",
    "apps/studio/tests/cloud-editor-browser.mjs": "811da20c52532f98b97ae7a30bb89b28513e77594faf3521aad0b3109c10409d",
    "apps/studio/tests/cloud-editor-fixture.tsx": "a28cd8b38d775992dd257bc9a5d2328609921840e6b5504547e372609c268850",
    "apps/studio/tests/cloud-editor-fixture.html": "a82b70ade21b95c43ff437cf5d4adec621a00eaca26fa87992ffae9367df6e17",
    "apps/studio/tests/runner-facts.mjs": "7aa46f9598f889352481c3b2b2810409b0f721c432f828329dfbae1d620b5821",
    "apps/studio/tests/native-trace-observer.mjs": "da47159e7f4c2222b31b03a0e0ed302ce1021d8695265896b2934140f44cccf6",
    "apps/studio/tests/scheduling-probe.mjs": "8b37e9f811ebf8ccc3929d3c251b20897505938e2a70c0ac765995a32a7ab8df",
    "apps/studio/tests/export-audio-output.mjs": "fbd316ee8a7328197a14e7f5eab64d4b767c92d99d335e221ff2ba17ee7e24d0",
    "apps/studio/package-lock.json": "6a5c79d8298e51c1b1a9c1a621afbca7940e737336554c0e929dbead7bd2c7df",
    ".github/workflows/ci.yml": "5db39bb0523729886ce9e5e57a9ebfa431642614db741c6303568d15bc174f10",
    "tools/ci/media-runner-ready.mjs": "e6bba983d0cb5b81db1f8de4c9ccd93dfc4d032d7acda182a5720a05420e9ff2",
    "tools/ci/native-media-cache.mjs": "777b22a37e628f008e301ea8281473dbd89939aa2854721381bd61123858554e",
    "tools/ci/browser-signature-policy.mjs": "ba94c76ba5fb41803d6af25bbb3e62e76f419a73c447552d2abe9ecf9c98da23",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(root: Path) -> str:
    files = sorted(path for path in root.rglob("*") if path.is_file())
    manifest = "".join(f"{path.relative_to(root).as_posix()}\t{digest(path)}\n" for path in files)
    return hashlib.sha256(manifest.encode()).hexdigest()


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"{label}: expected exactly one shipping anchor; found {source.count(old)}")
    return source.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", required=True, type=Path,
                        help="Disposable source copy of the exact shipping commit")
    parser.add_argument("--dependency-root", required=True, type=Path,
                        help="External npm install root; never the Studio node_modules")
    parser.add_argument("--receipt", required=True, type=Path,
                        help="External JSON manifest path")
    parser.add_argument("--validate-only", action="store_true",
                        help="Check pins and transform anchors without writing any file")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    dependency_root = args.dependency_root.resolve()
    receipt = args.receipt.resolve()
    here = Path(__file__).resolve().parent
    if checkout == here or here.is_relative_to(checkout) or checkout.is_relative_to(here):
        raise RuntimeError("Proof payload and disposable checkout must be separate")
    if not args.validate_only and checkout.name == "source" and checkout.parent.name == "client-native-speed-20261111":
        raise RuntimeError("Refusing to alter the active release checkout")
    if receipt.is_relative_to(checkout):
        raise RuntimeError("Receipt must remain outside the disposable checkout")
    for relative, expected in PINNED.items():
        actual = digest(checkout / relative)
        if actual != expected:
            raise RuntimeError(f"Shipping input mismatch: {relative} {actual}")
    entry = dependency_root / "node_modules/mediabunny/dist/modules/src/index.js"
    package = json.loads((dependency_root / "node_modules/mediabunny/package.json").read_text())
    lock_path = dependency_root / "package-lock.json"
    lock = json.loads(lock_path.read_text())
    locked = lock["packages"]["node_modules/mediabunny"]
    if not entry.is_file() or package.get("version") != "1.65.2" or \
            locked.get("version") != "1.65.2" or locked.get("integrity") != EXPECTED_INTEGRITY or \
            digest(entry) != EXPECTED_ENTRY_SHA256 or digest(lock_path) != EXPECTED_LOCK_SHA256 or \
            tree_digest(dependency_root / "node_modules/mediabunny") != EXPECTED_TREE_SHA256:
        raise RuntimeError("External Mediabunny pin or entry mismatch")

    editor_path = checkout / "apps/studio/src/editor/VideoEditor.tsx"
    editor = editor_path.read_text()
    editor = replace_once(editor, "  exportLocalVideo,\n", "", "shipping export import")
    editor = replace_once(editor, 'import "./editor.css";',
                          'import {exportNarratedWebCodecsProof} from "./experimental-webcodecs";\nimport "./editor.css";',
                          "proof import")
    editor = replace_once(editor, "const result = await exportLocalVideo({",
                          "const result = await exportNarratedWebCodecsProof({", "export call")

    browser_source = (checkout / "apps/studio/tests/cloud-editor-browser.mjs").read_text()
    browser_source = replace_once(browser_source,
        'import { mkdtemp, readFile, writeFile } from "node:fs/promises";',
        'import { mkdtemp, readFile, writeFile, readdir } from "node:fs/promises";',
        "package tree reader")
    browser_source = replace_once(browser_source,
        'import { startNativeTraceObserver, summarizeRecordingSilence, NATIVE_TRACE_EXPORT_LIMITS } from "./native-trace-observer.mjs";\n',
        "", "late native trace import")
    browser_source = replace_once(browser_source,
        'import { startNodeSchedulingProbe } from "./scheduling-probe.mjs";\n',
        "", "late scheduling probe import")
    browser_source = replace_once(browser_source,
        """const sourcePaths=["tests/cloud-editor-browser.mjs","tests/cloud-editor-fixture.tsx","tests/runner-facts.mjs","tests/native-trace-observer.mjs","tests/scheduling-probe.mjs",...['export','recording-clock','mp4-cadence','media','model','overlay-renderer'].map(name=>`src/editor/${name}.ts`)];""",
        """const sourcePaths=["tests/webcodecs-narrated-proof-browser.mjs","tests/cloud-editor-fixture.tsx","tests/runner-facts.mjs","src/editor/VideoEditor.tsx","src/editor/experimental-webcodecs.ts",...['export','recording-clock','mp4-cadence','media','model','overlay-renderer'].map(name=>`src/editor/${name}.ts`)];""",
        "source binding")
    browser_source = replace_once(browser_source,
        'const receipt = { proof: "Real CloudEditor, VideoEditor, DocumentSync and CloudPlanner with isolated cloud/asset fixtures. No live account or paid provider use.",',
        'const receipt = { proof: "Experimental WebCodecs first narrated case only, with isolated cloud/asset fixtures. No live account or paid provider use.", partialSuite:true, proofScope:"Three-second muted original-source video with OfflineAudioContext narration; no audible original clip or music parity claim", proofDownloads:0,',
        "proof label")
    begin = browser_source.index("// Test-only observation: every wrapper returns the original native result")
    end = browser_source.index("async function captureAudioOutputDevice(tab){", begin)
    browser_source = browser_source[:begin] + "async function captureMediaTiming(){ receipt.mediaTiming = []; }\n" + browser_source[end:]
    browser_source = replace_once(browser_source,
        "    await context.addInitScript(installMediaTimingFixture);\n", "", "old recorder observer")
    browser_source = replace_once(browser_source,
        'plugins:[exportRefusalReceiptPlugin], build:',
        'plugins:[exportRefusalReceiptPlugin], resolve:{alias:{mediabunny:process.env.WEBCODECS_PROOF_MEDIABUNNY_ENTRY}}, build:',
        "external dependency alias")
    browser_source = replace_once(browser_source,
        'const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-cloud-editor-")), dist = join(artifacts, "dist");',
        'const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-webcodecs-proof-")), dist = join(artifacts, "dist");',
        "diagnostic artifact root")
    browser_source = replace_once(browser_source, 'const timingDevices=[];', '''const timingDevices=[];
async function proofPackageTreeHash(base) {
  const paths=[];
  async function visit(dir,relative) {
    for(const entry of await readdir(dir,{withFileTypes:true})) {
      const name=relative?`${relative}/${entry.name}`:entry.name;
      if(entry.isDirectory()) await visit(join(dir,entry.name),name);
      else { assert(entry.isFile(),`Unexpected dependency entry ${name}`); paths.push(name); }
    }
  }
  await visit(base,""); paths.sort();
  const manifest=(await Promise.all(paths.map(async path=>
    `${path}\\t${createHash("sha256").update(await readFile(join(base,path))).digest("hex")}\\n`))).join("");
  return createHash("sha256").update(manifest).digest("hex");
}''', "dependency tree manifest")
    browser_source = replace_once(browser_source,
        '  receipt.loadBeforeExport.push({export:"narrated-studio",attempt:1,...quickLoad()});',
        '''  const muteControl = second.getByRole("combobox").filter({has: second.locator('option[value="muted"]')});
  await expect(muteControl).toHaveCount(1);
  await muteControl.selectOption("muted");
  await expect.poll(async () => (await second.evaluate(() => window.cloudFixture.snapshot()))
    .documents["edit:20000000-0000-4000-8000-000000000003"]?.payload.draft?.audio).toBe("muted");
  const sourceProbe = JSON.parse(execFileSync("ffprobe", ["-v","error","-show_streams","-of","json",sourceVideo], {encoding:"utf8"}));
  assert(!sourceProbe.streams.some(stream => stream.codec_type === "audio"), "The 2x source is synthetic silent video; this does not prove original sound or pitch");
  receipt.mutedSourceConfirmed = true;
  page = second; // Retain the actual proof device for failure screenshots.
  second.on("download", () => { receipt.proofDownloads++; });
  receipt.loadBeforeExport.push({export:"narrated-studio",attempt:1,...quickLoad()});''',
        "explicit muted fixture")
    browser_source = replace_once(browser_source,
        'assert(Math.abs(Number(probe.format.duration)-3)<0.4,`Speed-adjusted edit duration ${probe.format.duration}`);',
        'assert(Math.abs(Number(probe.format.duration)-3)<=2/30,`Exact 3s proof duration ${probe.format.duration}`);',
        "strict proof duration")
    browser_source = replace_once(browser_source,
        '  if(!await firstSave.isVisible()){',
        '''  const webCodecs = await second.evaluate(() => window.webCodecsNarratedProof ?? null);
  receipt.webCodecs = webCodecs;
  if(!await firstSave.isVisible()){
    assert.equal(receipt.proofDownloads, 0, "A refused proof must not create a download");
    assert.equal(await second.locator("a.rp-editor-download[download]").count(), 0,
      "A refused proof must not offer a download link");''',
        "retain encoded trace on success or refusal")
    cut = '  await second.evaluate(() => window.cloudFixture.loseComplete());'
    footer = '} catch (error) { receipt.status = "failed";'
    if browser_source.count(cut) != 1 or browser_source.count(footer) != 1:
        raise RuntimeError("First narrated proof truncation anchors drifted")
    start = browser_source.index(cut)
    end = browser_source.index(footer, start)
    final_checks = '''  assert(webCodecs && webCodecs.kind === "webcodecs-narrated-proof", "Actual WebCodecs proof trace missing");
  assert.equal(webCodecs.requested, 90, "Exactly 90 actual canvas VideoFrames must be submitted");
  assert.equal(webCodecs.encoded.length, 90, "Exactly 90 video packets must be returned");
  assert.equal(webCodecs.finalized, true);
  assert.equal(webCodecs.failed, false);
  const packetTimes = webCodecs.encoded.map(packet => {
    assert(Number.isFinite(packet.timestamp) && Number.isFinite(packet.duration));
    assert(packet.duration > 0 && packet.bytes > 0);
    return packet.timestamp;
  }).sort((a,b) => a-b); // Encoded callback order may be decode order with B-frames.
  for(let index=0;index<90;index++)
    assert(Math.abs(packetTimes[index]-index/30)<=.001, `Encoded packet ${index} presentation time drifted: ${packetTimes[index]}`);
  const frames = JSON.parse(execFileSync("ffprobe", ["-v","error","-select_streams","v:0","-show_frames","-show_entries","frame=best_effort_timestamp_time","-of","json",exported], {encoding:"utf8"})).frames;
  assert.equal(frames.length, 90, "Muxed MP4 must decode to exactly 90 video frames");
  const frameTimes = frames.map(frame => Number(frame.best_effort_timestamp_time)).sort((a,b) => a-b);
  for(let index=0;index<90;index++)
    assert(Math.abs(frameTimes[index]-index/30)<=.001, `Frame ${index} presentation timestamp drifted: ${frameTimes[index]}`);
  receipt.frameTimes = frameTimes;
  assert.equal(receipt.proofDownloads, 1, "Only the explicit successful proof download may occur");
  await second.screenshot({path:join(artifacts,"webcodecs-narrated-proof.png"),fullPage:true});
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []);
  receipt.status = "prototype-case-passed";
'''
    browser_source = browser_source[:start] + final_checks + browser_source[end:]
    start = browser_source.find('  if (receipt.nativeTrace?.renderGapSummary) try {')
    if start >= 0:
        end = browser_source.index("\n", start)
        browser_source = browser_source[:start] + browser_source[end + 1:]
    browser_source = replace_once(browser_source,
        '} catch (error) { receipt.status = "failed";',
        '} catch (error) { if(page && !page.isClosed()) receipt.webCodecs ??= await page.evaluate(() => window.webCodecsNarratedProof ?? null).catch(() => null); receipt.status = "failed";',
        "early proof failure trace")
    browser_source = replace_once(browser_source,
        'try {\n  await build(',
        'try {\n'
        f'  assert.equal(process.env.WEBCODECS_PROOF_MEDIABUNNY_ENTRY, {json.dumps(str(entry))}, "Exact external Mediabunny alias required");\n'
        f'  receipt.dependencyTreeBefore=await proofPackageTreeHash({json.dumps(str(dependency_root / "node_modules/mediabunny"))});\n'
        f'  assert.equal(receipt.dependencyTreeBefore, "{EXPECTED_TREE_SHA256}", "Pinned Mediabunny package tree changed before proof");\n'
        '  await build(', "runtime dependency binding")
    browser_source = replace_once(browser_source,
        'receipt.sourceBoundAtEnd=JSON.stringify(await sourceHashes())===JSON.stringify(receipt.sourceHashes); await writeFile(',
        'try { receipt.sourceBoundAtEnd=JSON.stringify(await sourceHashes())===JSON.stringify(receipt.sourceHashes); '
        f'receipt.dependencyTreeAfter=await proofPackageTreeHash({json.dumps(str(dependency_root / "node_modules/mediabunny"))}); '
        '} catch(error) { receipt.bindingError=String(error); } '
        f'if(receipt.sourceBoundAtEnd!==true || receipt.dependencyTreeAfter!=="{EXPECTED_TREE_SHA256}") '
        '{ receipt.status="failed"; receipt.failure=[receipt.failure,"Proof source or dependency changed during run."].filter(Boolean).join("\\n"); process.exitCode=1; } '
        'await writeFile(', "end-of-proof source and dependency binding")

    proof_path = checkout / "apps/studio/src/editor/experimental-webcodecs.ts"
    test_path = checkout / "apps/studio/tests/webcodecs-narrated-proof-browser.mjs"
    for path in (proof_path, test_path):
        if path.exists():
            raise RuntimeError(f"Refusing to overwrite an existing diagnostic file: {path}")
    if args.validate_only:
        generated = {
            "experimental-webcodecs.ts": digest(here / "experimental-webcodecs.ts"),
            "VideoEditor.tsx": hashlib.sha256(editor.encode()).hexdigest(),
            "webcodecs-narrated-proof-browser.mjs": hashlib.sha256(browser_source.encode()).hexdigest(),
        }
        print(json.dumps({"status": "validated-without-writes", "pinnedInputs": len(PINNED),
                          "generatedSha256": generated}, indent=2))
        return
    proof_path.write_bytes((here / "experimental-webcodecs.ts").read_bytes())
    editor_path.write_text(editor)
    test_path.write_text(browser_source)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({
        "kind": "webcodecs-narrated-prototype-preparation-v1",
        "shippingCommit": SHIPPING_SHA,
        "shippingPinsSha256": PINNED,
        "externalDependency": {"name": "mediabunny", "version": "1.65.2",
                               "lockIntegrity": EXPECTED_INTEGRITY,
                               "packageLockSha256": digest(lock_path),
                               "entrySha256": digest(entry),
                               "packageTreeSha256": tree_digest(dependency_root / "node_modules/mediabunny"),
                               "entry": str(entry)},
        "preparedSha256": {str(path.relative_to(checkout)): digest(path)
                           for path in (proof_path, editor_path, test_path)},
        "status": "prepared-not-run",
    }, indent=2) + "\n")
    print("Prepared disposable first-case proof; no build or browser run.")


if __name__ == "__main__":
    main()
