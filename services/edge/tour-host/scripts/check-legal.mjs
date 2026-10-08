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
expect(t.includes("account-based workspace") && t.includes("sign in with Apple") && t.includes("one published listing free"), "Terms state the account requirement and the free tier");
expect(p.includes("Account details") && p.includes("older guest session"), "Privacy covers the account identity and legacy guest sessions");
expect(p.includes("scripts or transcript excerpts") && p.includes("personal information"), "AI inventory covers text and potentially identifying content");
provider("Google Gemini", ["Selected photos or video", "text inputs"]);
provider("fal.ai", ["prompts", "video"]);
provider("Anthropic", ["chat history", "source photos", "generated clips"]);
provider("OpenAI", ["chat history", "photo editing", "generated-clip frames"]);
provider("ElevenLabs", ["voiceover script", "address", "selected voice"]);
provider("Apple", ["Speech recognition", "Recorded voiceover audio", "falls back to the server"]);
provider("Supabase", ["Inputs sent through Rendprop's API", "media and text"]);
provider("GoHighLevel (LeadConnector)", ["legacy CRM", "automatic export of new inquiries is disabled"]);
provider("Resend", ["email-address verification", "verified listing contacts"]);
provider("RentCast", ["property-record lookups", "listing address"]);
provider("Bria", ["video masking", "Selected video clips"]);
provider("cdnjs and jsDelivr", ["viewer’s IP".replace("’", "'"), "player software"]);
expect(p.includes("Automatic CRM export is disabled"), "No silent export to a global agency CRM");
expect(p.includes("verified email address") && p.includes("does not subscribe the buyer"), "Inquiry routing and marketing consent are distinct");
expect(!p.includes("Those same details") && !p.includes("other than the CRM"), "No inaccurate universal CRM recipient claim");
expect(p.includes("fallback or quality checks"), "Multiple-provider execution is disclosed");
expect(t.includes("workspaces shared with other members can remain"), "Terms distinguish shared workspace data");
expect(t.includes("whether further cleanup is pending"), "Terms distinguish request and cleanup completion");
expect(!t.includes("normally within hours") && !t.includes("everything in it"), "No unsupported immediate/universal deletion promise");
expect(p.includes("Account deletion and associated cleanup are separate statuses"), "Privacy distinguishes cleanup completion");
expect(!p.includes("account removes your data"), "Summary does not erase deletion qualifications");
for (const [label, html] of [["Privacy", privacy], ["Terms", terms]]) {
  expect(html.includes("#7c3aed") && html.includes("#9b6dff"), `${label}: existing light/dark brand accents`);
  expect(html.includes('<html lang="en">') && html.includes('name="viewport"'), `${label}: language and mobile viewport`);
  expect(html.includes('href="/support"') && html.includes('mailto:aaron@pilk.ai'), `${label}: support and contact preserved`);
  expect(html.includes("Effective October 8, 2026"), `${label}: proposed notice revision date`);
  expect(html.includes("RendProp LLC") && html.includes("855 Central Avenue, Saint Petersburg, FL 33701"), `${label}: owner-supplied legal entity and mailing address`);
  expect(!/<script\b/i.test(html), `${label}: no third-party scripts or telemetry added`);
}
expect(t.includes("without your written consent") && p.includes("without your written consent"), "Written-consent commitment retained");
expect(t.includes("90-day grace period") && t.includes("advance notices") && t.includes("download your content"), "Prospective hosting grace preserves notice and download opportunity");
expect(t.includes("Existing testers retain") && p.includes("Existing testers retain"), "Existing tester hosting arrangements remain separate");
expect(!t.includes("share links you have already sent keep working") && !p.includes("Your content remains until you request deletion"), "No new permanent hosting promise");
expect(t.includes("at least 18 years old") && p.includes("adults aged 18 or older"), "Adult business audience matches documented AI provider age restrictions");
expect(p.includes("Settings → Download account data") && p.includes("scope and omissions") && p.includes("separate download controls"), "Account JSON export and binary-media limits are stated");
expect(p.includes("Provider copies can remain") && p.includes("paid and unpaid processing") && p.includes("video results do not expire by default"), "Provider retention is not inferred from Rendprop URL expiry");
expect(!p.includes("They process data solely"), "No unsupported universal processor-use guarantee");
expect(t.includes("Starter and Pro, billed monthly") && t.includes("Team, billed monthly"), "Payment terms not rewritten");
expect(t.includes("by confirming an Apple subscription") && t.includes("Downloading or signing in does not activate a trial"), "Trial requires eligible Apple subscription activation");
expect(t.includes("One introductory") || t.includes("one introductory offer per subscription group"), "Trial eligibility remains Apple subscription-group scoped");
expect(t.includes("when a funded trial offer is available") && t.includes("does not move Apple's renewal date forward"), "Limited trial availability and Apple billing date are distinct");
expect(p.includes("one-way digest") && p.includes("still account-related data") && p.includes("remain after listing or account deletion"), "Retained trial eligibility metadata and its deletion limit are disclosed");
expect(t.includes("account, workspace and plan") && t.includes("does not reset Rendprop's trial reservation") && p.includes("reservation date and funding commitment") && p.includes("does not reset after cancellation or an interrupted purchase"), "Pre-Apple trial reservation and retained account-related commitment are disclosed");
expect(p.includes("do not keep the deleted photos or videos available"), "Trial tombstones do not promise retained deleted media");
for (const filename of ["index.html", "pricing.html", "llms.txt"]) {
  const copy = readFileSync(new URL(`../public/${filename}`, import.meta.url), "utf8");
  expect(!/every (?:new install|plan) (?:also gets|starts with)|free week with no card/i.test(copy), `${filename}: no automatic signup-week or universal trial promise`);
  expect(/eligible/i.test(copy) && /confirm/i.test(copy) && /Apple/i.test(copy), `${filename}: eligibility and subscription activation disclosed`);
  if (filename.endsWith(".html")) for (const [, json] of copy.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)) {
    try { JSON.parse(json); expect(true, `${filename}: valid structured data`); }
    catch { expect(false, `${filename}: valid structured data`); }
  }
}
expect(p.includes("180 days") && p.includes("applicable retention settings") && !p.includes("short, fixed schedule"), "No invented universal backup/log retention period");
expect(privacy.includes('aria-label="Service providers and data processing"'), "Responsive table keeps a descriptive name");
expect((privacy.match(/role="row"/g) || []).length === 14, "All header/provider rows retain explicit roles");
expect((privacy.match(/role="cell"/g) || []).length === 39, "All provider cells retain explicit roles");
expect((privacy.match(/scope="col"/g) || []).length === 3, "All table headers retain column scope");
if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join("\n"));
  console.error(`Legal-page check: ${assertions} assertions, ${failures.length} failed, 0 skipped`);
  process.exit(1);
}
console.log(`Legal-page check: ${assertions} assertions, 0 failed, 0 skipped; actual emitted HTML, no provider calls`);
