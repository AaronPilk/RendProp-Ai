// Static regression guard, NOT a replacement for the actual XCTest UI run.
// Evidence: d05bbec Reviewer.xcresult, attachment
// 8C7332FD-AF08-47FF-8AC2-F8964FF96C45.txt. That real tree exposes
// ScrollView aiConsent.root with agree/decline descendants, no aiConsent.scroll.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../apps/ios/Rendprop/RendpropApp.swift', import.meta.url), 'utf8');
const walk = readFileSync(new URL('../../apps/ios/RendpropUITests/ReviewerWalk.swift', import.meta.url), 'utf8');
const consent = app.slice(app.indexOf('struct AIConsentView: View {'), app.indexOf('    private func bullet(', app.indexOf('struct AIConsentView: View {')));
const action = walk.slice(walk.indexOf('    private func consentAction('), walk.indexOf('    // MARK: - Navigation helpers', walk.indexOf('    private func consentAction(')));

test('one canonical ID is explicitly attached to the consent ScrollView, not inherited from ZStack', () => {
  assert.equal((consent.match(/accessibilityIdentifier\("aiConsent.root"\)/g) ?? []).length, 1);
  assert.equal(consent.includes('aiConsent.scroll'), false);
  // This is the ScrollView modifier position, before the enclosing ZStack ends.
  assert.match(consent, /\n {12}\.accessibilityIdentifier\("aiConsent.root"\)\n {8}\}/);
  assert.doesNotMatch(consent, /\n {8}\.accessibilityIdentifier\("aiConsent.root"\)/);
});

test('typed selector matches the actual failing-run scroll identity and scopes actions to it', () => {
  assert.match(action, /app\.scrollViews\.matching\(identifier: "aiConsent.root"\)/);
  assert.match(action, /scrolls\.count == 1/);
  assert.match(action, /scroll\.buttons\[identifier\]/);
  assert.doesNotMatch(action, /app\.buttons\[identifier\]|firstMatch.*\|\||coordinate/);
});

test('full containment, hit testing, enabled state and bounded scrolling remain mandatory', () => {
  for (const condition of ['action.exists', 'action.isEnabled', 'action.isHittable',
    'action.frame.width > 0', 'action.frame.height > 0', 'scroll.frame.contains(action.frame)',
    'for attempt in 0...8', 'scroll.swipeUp()', 'note("Consent action is not fully visible']) {
    assert.ok(action.includes(condition), `lost required reachability condition: ${condition}`);
  }
});

test('focused test reuses the actual decline-reopen-agree flow and requires all three attachments', () => {
  const focused = walk.match(/func testAIConsentDecisions\(\) \{([\s\S]*?)\n    \}/)?.[1];
  assert.ok(focused, 'focused XCTest method missing');
  assert.ok(focused.includes('step11AIConsent()'));
  for (const name of ['r11-ai-consent', 'r11b-consent-actions', 'r11c-consent-granted']) {
    assert.ok(focused.includes(name));
  }
  assert.match(walk, /name\.contains\("testAIConsentDecisions"\)/);
  assert.match(walk, /app\.launchArguments \+= \["-hasOnboarded", "YES"\]/);
});
