#!/usr/bin/env node
// Exercise the emitted pages, not a second copy of their text. These checks
// establish disclosure coverage, not vendor contracts or legal compliance.
import { buildSrc } from "./build-src.mjs";
import {readFileSync} from "node:fs";

globalThis.fetch = () => { throw new Error("unexpected network in legal-page check"); };
const load = buildSrc("legal-flow-check-20260910");
const { privacyPage, termsPage } = await load("legal");
const privacy = privacyPage(), terms = termsPage();
const flat = (html) => html.replace(/<[^>]*>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ");
const p = flat(privacy), t = flat(terms);
let assertions = 0;
const failures = [];
function expect(condition, label) { assertions++; if (!condition) failures.push(label); }
const rows = [...privacy.matchAll(/<tr(?:\s[^>]*)?>(.*?)<\/tr>/gs)].map(([html]) => flat(html));
function provider(name, inputs) {
  const matches = rows.filter((row) => row.startsWith(` ${name} `));
  expect(matches.length === 1, `${name}: exactly one provider row`);
  for (const input of inputs) expect(matches.length === 1 && matches[0].includes(input), `${name}: ${input}`);
}
expect(t.includes("guest session") && t.includes("Apple is optional"), "Terms disclose guest sessions and optional Apple sign-in");
expect(p.includes("Account and session details") && p.includes("guest session"), "Privacy covers guest identifiers");
expect(p.includes("scripts or transcript excerpts") && p.includes("personal information"), "AI inventory covers text and potentially identifying content");
provider("Google Gemini", ["Selected photos or video", "text inputs"]);
provider("fal.ai", ["prompts", "video"]);
provider("Anthropic", ["chat history", "source photos", "generated clips"]);
provider("OpenAI", ["chat history", "photo editing", "generated-clip frames"]);
provider("ElevenLabs", ["voiceover script", "address", "selected voice"]);
provider("Apple", ["Speech recognition", "Recorded voiceover audio", "falls back to the server"]);
provider("Supabase", ["Inputs sent through Rendprop's API", "media and text"]);
provider("GoHighLevel (LeadConnector)", ["workspace and listing tags", "listing address"]);
expect(p.includes("When CRM sync is configured"), "CRM delivery is conditional");
expect(p.includes("message or preferred date remains"), "CRM subset distinguished from stored lead details");
expect(!p.includes("Those same details") && !p.includes("other than the CRM"), "No inaccurate universal CRM recipient claim");
expect(p.includes("fallback or quality checks"), "Multiple-provider execution is disclosed");
expect(t.includes("workspaces shared with other members can remain"), "Terms distinguish shared workspace data");
expect(t.includes("whether further cleanup is pending"), "Terms distinguish request and cleanup completion");
expect(!t.includes("normally within hours") && !t.includes("everything in it"), "No unsupported immediate/universal deletion promise");
expect(p.includes("Account deletion and completion of associated cleanup are separate statuses"), "Privacy distinguishes cleanup completion");
expect(!p.includes("account removes your data"), "Summary does not erase deletion qualifications");
for (const [label, html] of [["Privacy", privacy], ["Terms", terms]]) {
  expect(html.includes("#7c3aed") && html.includes("#9b6dff"), `${label}: existing light/dark brand accents`);
  expect(html.includes('<html lang="en">') && html.includes('name="viewport"'), `${label}: language and mobile viewport`);
  expect(html.includes('href="/support"') && html.includes('mailto:aaron@pilk.ai'), `${label}: support and contact preserved`);
  expect(html.includes("Effective September 5, 2026"), `${label}: effective date not silently revised`);
  expect(!/<script\b/i.test(html), `${label}: no third-party scripts or telemetry added`);
}
expect(t.includes("without your written consent") && p.includes("without your written consent"), "Written-consent commitment retained");
expect(t.includes("Starter and Pro, billed monthly") && t.includes("Team, billed monthly"), "Payment terms not rewritten");
expect(t.includes("by confirming an Apple subscription") && t.includes("Downloading or signing in does not activate a trial"), "Trial requires eligible Apple subscription activation");
expect(t.includes("One introductory") || t.includes("one introductory offer per subscription group"), "Trial eligibility remains Apple subscription-group scoped");
for (const filename of ["index.html", "pricing.html", "llms.txt"]) {
  const copy = readFileSync(new URL(`../public/${filename}`, import.meta.url), "utf8");
  expect(!/every (?:new install|plan) (?:also gets|starts with)|free week with no card/i.test(copy), `${filename}: no automatic signup-week or universal trial promise`);
  expect(/eligible/i.test(copy) && /confirm/i.test(copy) && /Apple/i.test(copy), `${filename}: eligibility and subscription activation disclosed`);
  if (filename.endsWith(".html")) for (const [, json] of copy.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)) {
    try { JSON.parse(json); expect(true, `${filename}: valid structured data`); }
    catch { expect(false, `${filename}: valid structured data`); }
  }
}
expect(p.includes("deleted 180 days") && p.includes("short, fixed schedule"), "Retention claims unchanged and still require operational approval");
expect(privacy.includes('aria-label="Service providers and data processing"'), "Responsive table keeps a descriptive name");
expect((privacy.match(/role="row"/g) || []).length === 10, "All header/provider rows retain explicit roles");
expect((privacy.match(/role="cell"/g) || []).length === 27, "All provider cells retain explicit roles");
expect((privacy.match(/scope="col"/g) || []).length === 3, "All table headers retain column scope");
if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join("\n"));
  console.error(`Legal-page check: ${assertions} assertions, ${failures.length} failed, 0 skipped`);
  process.exit(1);
}
console.log(`Legal-page check: ${assertions} assertions, 0 failed, 0 skipped; actual emitted HTML, no provider calls`);
