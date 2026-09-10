// Copy/source contracts plus the exact production AIConsent class running with
// isolated real Foundation preferences across three executable invocations.
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

test('production uses only the material-disclosure v2 key', () => {
  assert.match(production, /private static let storageKey = "ai\.thirdPartyProcessing\.consent\.v2"/);
  assert.doesNotMatch(production, /"ai\.thirdPartyProcessing\.consent\.v1"/);
});

test('all current UI launch overrides target v2; historical receipts are not rewritten', () => {
  const directory = new URL('../../apps/ios/RendpropUITests/', import.meta.url);
  let configured = 0;
  for (const name of readdirSync(directory).filter((name) => name.endsWith('.swift'))) {
    const source = readFileSync(new URL(name, directory), 'utf8');
    assert.doesNotMatch(source, /ai\.thirdPartyProcessing\.consent\.v1/, name);
    if (source.includes('-ai.thirdPartyProcessing.consent.v2')) configured += 1;
  }
  assert.equal(configured, 8, 'review every current consent launch fixture');
});

test('actual consent grant, relaunch, revoke, decline and cancel with isolated persisted defaults', () => {
  const dir = mkdtempSync(join(tmpdir(), 'rendprop-consent-policy.'));
  const support = readFileSync(new URL('AIConsentPersistenceTests.swift', import.meta.url), 'utf8');
  const extracted = join(dir, 'AIConsent.swift');
  const harness = join(dir, 'Persistence.swift');
  // Mechanical extraction only; assertions never run a copied consent body.
  writeFileSync(extracted, `import Foundation\nimport Combine\n${production}\n`, { flag: 'wx' });
  writeFileSync(harness, support, { flag: 'wx' });
  const binary = join(dir, 'consent-persistence');
  const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', extracted, harness, '-o', binary],
    { encoding: 'utf8', timeout: 60000 });
  assert.equal(compile.status, 0, `Swift compile failed: ${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
  const suite = `com.rendprop.offline-consent-tests.${randomUUID()}`;
  console.log(`Evidence: ${dir}; isolated preferences suite: ${suite}`);
  const run = (scenario) => spawnSync(binary, [scenario, suite], { encoding: 'utf8', timeout: 5000 });
  const negative = run('deliberate-unknown-scenario');
  assert.equal(negative.status, 1, 'negative control must fail with exit 1');
  assert.match(negative.stdout, /FAIL: unknown scenario/);
  for (const scenario of ['v1-only-then-grant', 'relaunch-then-revoke', 'relaunch-then-decline']) {
    const result = run(scenario);
    assert.equal(result.status, 0, `${scenario}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /^PASS \d+ assertions:/m);
    console.log(result.stdout.trim());
  }
});
