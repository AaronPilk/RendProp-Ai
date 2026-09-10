// Source guard only. A full accessibility label can coexist with visible
// truncation, so the rebuilt screenshot remains the legibility proof.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

test('Ask AI keeps its intrinsic label and a 44-point touch target', () => {
  const source = readFileSync(new URL('../../apps/ios/Rendprop/Coach/AskAIButton.swift', import.meta.url), 'utf8');
  const control = source.slice(source.indexOf('struct AskAIButton: View {'));
  assert.match(control, /Text\("Ask AI"\)/);
  assert.match(control, /\.fixedSize\(horizontal: true, vertical: false\)/);
  assert.match(control, /\.frame\(minWidth: 76, minHeight: 44\)/);
  assert.match(control, /\.accessibilityIdentifier\("askAI"\)/);
});
