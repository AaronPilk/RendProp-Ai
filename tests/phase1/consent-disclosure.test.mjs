// Copy/source contracts plus the exact production AIConsent class running with
// isolated real Foundation preferences across separate executable invocations.
// NOT SwiftUI/device/network/provider-policy verification. No installations.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const appURL = new URL('../../apps/ios/Rendprop/RendpropApp.swift', import.meta.url);
const app = readFileSync(appURL, 'utf8');
const begin = app.indexOf('@MainActor\nfinal class AIConsent: ObservableObject {');
const end = app.indexOf('\n/// Attach to an AI surface.', begin);
assert.ok(begin >= 0 && end > begin, 'exact production class boundaries required');
const production = app.slice(begin, end);
const expected = [
  ['Google (Gemini)', 'Receives photos, video or text for photo editing, video analysis and writing assistance.'],
  ['fal.ai', 'Receives photos, video and prompts for AI edits, generated clips and upscaling. Available models include ByteDance Seedance, Google Veo, Topaz Labs, Bria, FLUX and MiniMax Hailuo.'],
  ['Bria', 'Receives the video intervals you select, removal prompts and generated masks to remove people, objects or reflections from video.'],
  ['Anthropic and OpenAI', 'Receive chat, project context and writing requests. Quality checks can also send source photos and frames from generated clips; OpenAI can edit photos.'],
  ['ElevenLabs', 'Receives your voiceover script, including any address or personal details in it, and your selected voice to generate narration.'],
];

test('exact processor cards distinguish services, model attribution and media quality checks', () => {
  const cards = [...production.matchAll(/Processor\(name: "([^"]+)",\s+detail: "([^"]+)"\)/g)]
    .map((match) => [match[1], match[2]]);
  assert.deepEqual(cards, expected);
});

test('disclosure names actual input types and avoids global never-send promises', () => {
  const view = app.slice(app.indexOf('struct AIConsentView: View {'), app.indexOf('// MARK: - Storefront'));
  for (const text of [
    "Cloud AI tools send the media, text and project context needed for your request through Rendprop's servers to the providers below. Some tools use more than one provider, including for quality checks or fallback.",
    'What we send depends on the tool: selected media and sampled frames, edit prompts, chat history, project context, script text and transcript excerpts. For aerials, enter only city and state in the region field.',
    'Review before sending: media can show people, addresses or documents. Text and project labels can contain personal information. Remove anything you do not want processed by these providers.',
    'These services process what is sent to return your result. Rendprop does not sell your media and does not use it for advertising.',
  ]) assert.ok(view.includes(`"${text}"`), `missing exact reviewed copy: ${text}`);
  assert.doesNotMatch(production + view, /What we never send:|photos and videos are never sent|retained for|no.training guarantee|automatically anonymized/);
  for (const required of ['Agree and continue', 'Not now', 'Read the Privacy Policy',
    'aiConsent.agree', 'aiConsent.decline', 'aiConsent.root', 'Settings → Your data']) {
    assert.ok(view.includes(required), `mandatory disclosure/action removed: ${required}`);
  }
});

test('production uses only the direct-Bria material-disclosure v3 key', () => {
  assert.match(production, /private static let storageKey = "ai\.thirdPartyProcessing\.consent\.v3"/);
  assert.doesNotMatch(production, /"ai\.thirdPartyProcessing\.consent\.v[12]"/);
});

test('all current UI launch overrides target v3; historical receipts are not rewritten', () => {
  const directory = new URL('../../apps/ios/RendpropUITests/', import.meta.url);
  const configured = [];
  for (const name of readdirSync(directory).filter((name) => name.endsWith('.swift'))) {
    const source = readFileSync(new URL(name, directory), 'utf8');
    assert.doesNotMatch(source, /ai\.thirdPartyProcessing\.consent\.v[12]/, name);
    if (source.includes('-ai.thirdPartyProcessing.consent.v3')) configured.push(name);
    if (['CaptureRecoveryTests.swift', 'SubscriptionFlowTests.swift'].includes(name)) {
      assert.match(source, /"-ai\.thirdPartyProcessing\.consent\.v3", "NO"/,
        'offline recovery and billing fixtures keep cloud AI consent declined');
    }
  }
  assert.deepEqual(configured.sort(), [
    'BetaPolishUITests.swift', 'CaptureRecoveryTests.swift', 'CoachShot.swift', 'DetailMetadataRegressionUITests.swift', 'GuideShot.swift', 'GuidedPhotoNavigationTests.swift', 'IndustryWalk.swift',
    'OnboardingTour.swift', 'PaywallShot.swift', 'RendpropUITests.swift', 'ReviewerWalk.swift', 'StoreShots.swift', 'SubscriptionFlowTests.swift',
  ], 'review every current consent launch fixture explicitly');
  for (const name of ['README.md', 'bridge-cmd-reviewerwalk.sh']) {
    const source = readFileSync(new URL(name, directory), 'utf8');
    assert.doesNotMatch(source, /ai\.thirdPartyProcessing\.consent\.v[12]/, name);
    assert.ok(source.includes('-ai.thirdPartyProcessing.consent.v3'), `${name}: current launch guidance must use v3`);
  }
});

function compileConsent(source) {
  const dir = mkdtempSync(join(tmpdir(), 'rendprop-consent-policy.'));
  const support = readFileSync(new URL('AIConsentPersistenceTests.swift', import.meta.url), 'utf8');
  const extracted = join(dir, 'AIConsent.swift');
  const harness = join(dir, 'Persistence.swift');
  // Mechanical extraction only; assertions never run a copied consent body.
  writeFileSync(extracted, `import Foundation\nimport Combine\n${source}\n`, { flag: 'wx' });
  writeFileSync(harness, support, { flag: 'wx' });
  const binary = join(dir, 'consent-persistence');
  const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', extracted, harness, '-o', binary],
    { encoding: 'utf8', timeout: 60000 });
  assert.equal(compile.status, 0, `Swift compile failed: ${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
  return { dir, run: (scenario, suite) => spawnSync(binary, [scenario, suite], { encoding: 'utf8', timeout: 5000 }) };
}

let actualExecutable;
function actualConsent() {
  actualExecutable ??= compileConsent(production);
  return actualExecutable;
}

function assertPass(result, scenario) {
  assert.equal(result.status, 0, `${scenario}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^PASS \d+ assertions:/m);
  console.log(result.stdout.trim());
}

test('actual consent grant, relaunch, revoke, decline and cancel with isolated persisted defaults', () => {
  const { dir, run } = actualConsent();
  const suite = `com.rendprop.offline-consent-tests.${randomUUID()}`;
  console.log(`Evidence: ${dir}; isolated preferences suite: ${suite}`);
  const negative = run('deliberate-unknown-scenario', suite);
  assert.equal(negative.status, 1, 'negative control must fail with exit 1');
  assert.match(negative.stdout, /FAIL: unknown scenario/);
  for (const scenario of ['v1-only-then-grant', 'relaunch-then-revoke', 'relaunch-then-decline']) {
    assertPass(run(scenario, suite), scenario);
  }
});

test('an old v2 grant followed by relaunch cannot authorize the new direct Bria disclosure', () => {
  const { dir, run } = actualConsent();
  const suite = `com.rendprop.offline-consent-tests.${randomUUID()}`;
  console.log(`v2 migration evidence: ${dir}; isolated preferences suite: ${suite}`);
  for (const scenario of ['seed-old-v2-grant', 'v2-relaunch-requires-disclosure']) {
    assertPass(run(scenario, suite), scenario);
  }
});

test('privacy negative control catches silently reusing the old v2 grant', () => {
  const mutated = production.replace(
    'private static let storageKey = "ai.thirdPartyProcessing.consent.v3"',
    'private static let storageKey = "ai.thirdPartyProcessing.consent.v2"');
  assert.notEqual(mutated, production, 'negative control must change the actual consent storage key');
  const { run } = compileConsent(mutated);
  const suite = `com.rendprop.offline-consent-tests.${randomUUID()}`;
  assertPass(run('seed-old-v2-grant', suite), 'seed-old-v2-grant');
  const negative = run('v2-relaunch-requires-disclosure', suite);
  assert.equal(negative.status, 1, 'reusing v2 must fail the real persistence/privacy check');
  assert.match(negative.stdout, /FAIL: a persisted v2 YES must not grant direct Bria v3/);
});
