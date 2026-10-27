#!/usr/bin/env node
// Exercise the emitted pages, not a second copy of their text. These checks
// establish disclosure coverage, not vendor contracts or legal compliance.
import { buildSrc } from "./build-src.mjs";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";

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
expect(t.includes("account-based workspace") && t.includes("sign in with Apple") && t.includes("The app is the source of truth"), "Terms state the account requirement and where current plan terms appear");
expect(p.includes("Account details") && p.includes("older guest session"), "Privacy covers the account identity and legacy guest sessions");
expect(p.includes("scripts or transcript excerpts") && p.includes("personal information"), "AI inventory covers text and potentially identifying content");
provider("Google Gemini", ["Selected photos or video", "text inputs"]);
provider("fal.ai", ["prompts", "video", "earlier aerial intros"]);
provider("Kie (kie.ai)", ["separate explicit permission", "AI Aerial openings", "selected property photos", "reviewed front exterior crop", "temporary download link", "camera-motion instructions"]);
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
  expect(html.includes("Effective October 27, 2026"), `${label}: proposed notice revision date`);
  expect(html.includes("RendProp LLC") && html.includes("855 Central Avenue, Saint Petersburg, FL 33701"), `${label}: owner-supplied legal entity and mailing address`);
  expect(!/<script\b/i.test(html), `${label}: no third-party scripts or telemetry added`);
}
expect(t.includes("without your written consent") && p.includes("without your written consent"), "Written-consent commitment retained");
expect(t.includes("requires separate permission") && p.includes("not covered by an earlier AI permission"), "Kie never inherits earlier processor permission");
expect(t.includes("optional paid AI Aerial opening") && t.includes("eligible paid access") && t.includes("remaining Aerial allowance")
  && t.includes("available processing capacity") && t.includes("separate permission for the listed")
  && t.includes("older free-form Aerial generator remains private and closed"),
  "Terms distinguish eligible paid scoped opening from closed legacy generation");
expect(t.includes("not captured drone footage or a 3D representation") && t.includes("quality is not guaranteed")
  && t.includes("previously saved aerial clips remain accessible") && !/New aerial creation is Coming soon/i.test(t),
  "Terms disclose generated footage limits and retained saved clips without stale availability claims");
expect(p.includes("source assessment, generation and finished-clip checks") && p.includes("reviewed original front exterior photo or its prepared crop")
  && p.includes("OpenAI and Anthropic") && p.includes("older free-form Aerial generator remains closed"),
  "Privacy explains the separate Aerial processor scope and source/clip checks");
expect(p.includes("14 days") && p.includes("two months") && p.includes("does not state how long fetched input photos"), "Kie retention separates documented output/log lifetimes from unknown input retention");
expect(t.includes("do not expressly rule out AI model training") && p.includes("do not expressly rule out AI model training"), "Kie improvement license disclosed without claiming training or a no-training guarantee");
expect(p.includes("withdraw permission for future requests") && p.includes("already accepted work may finish"), "Withdrawal stops future authority without promising recall");
expect(t.includes("90-day grace period") && t.includes("advance notices") && t.includes("download your content"), "Prospective hosting grace preserves notice and download opportunity");
expect(t.includes("Existing testers retain") && p.includes("Existing testers retain"), "Existing tester hosting arrangements remain separate");
expect(!t.includes("share links you have already sent keep working") && !p.includes("Your content remains until you request deletion"), "No new permanent hosting promise");
expect(t.includes("at least 18 years old") && p.includes("adults aged 18 or older"), "Adult business audience matches documented AI provider age restrictions");
expect(p.includes("Settings → Download account data") && p.includes("scope and omissions") && p.includes("separate download controls"), "Account JSON export and binary-media limits are stated");
expect(p.includes("Provider copies can remain") && p.includes("paid and unpaid processing") && p.includes("video results do not expire by default"), "Provider retention is not inferred from Rendprop URL expiry");
expect(!p.includes("They process data solely"), "No unsupported universal processor-use guarantee");
expect(t.includes("Launch plans and included usage are being finalized") && t.includes("The app is the source of truth") && t.includes("Apple shows the price, billing period"), "Terms defer current plan features and purchase terms to the app and Apple");
expect(t.includes("If Apple presents an introductory offer") && t.includes("Downloading or signing in does not activate an offer") && t.includes("purchase sheet control"), "Introductory offers depend on Apple's purchase sheet, not download or sign-in");
expect(t.includes("introductory offer eligibility, duration, renewal price, and terms before confirmation") && !/one introductory offer per subscription group/i.test(t), "Apple shows offer eligibility without a fixed group-level promise");
expect(t.includes("Apple charges the price and billing schedule shown when you confirm") && t.includes("first charge after any applicable free trial") && !t.includes("limited to a trial usage ceiling"), "Terms distinguish Apple's conditional offer from unapproved usage ceilings");
expect(!t.includes("funded trial offer") && !t.includes("trial reservation"), "Terms do not promise an operator-funded or reserved trial");
expect(p.includes("one-way digest") && p.includes("still account-related data") && p.includes("remain after listing or account deletion"), "Retained trial eligibility metadata and its deletion limit are disclosed");
expect(p.includes("AI usage holds and costs") && p.includes("prevents repeat trials or") && p.includes("Limited purchase-eligibility and usage-accounting records may remain"), "Privacy describes retained eligibility and usage records without promising a fixed trial policy");
expect(p.includes("do not keep the deleted photos or videos available"), "Trial tombstones do not promise retained deleted media");
expect(!/one published listing free|Starter, Pro and Team, each|limited to a trial usage ceiling|reinstalling, cancelling or changing workspaces does not create another trial/i.test(t), "Terms omit superseded free-listing, fixed-plan and guaranteed-trial promises");
for (const filename of ["index.html", "pricing.html", "llms.txt"]) {
  const copy = readFileSync(new URL(`../public/${filename}`, import.meta.url), "utf8");
  expect(!/every (?:new install|plan) (?:also gets|starts with)|free week with no card|one published listing free|first (?:published )?listing (?:is )?free|limited to a trial usage ceiling/i.test(copy), `${filename}: no automatic free-listing, signup-week or fixed trial-usage promise`);
  expect(/(?:plan features|subscription options|current plan features)/i.test(copy) && /introductory offer/i.test(copy) && /Apple/i.test(copy) && /before confirm(?:ation|ing)/i.test(copy), `${filename}: current plan source and conditional Apple offer terms disclosed`);
  if (filename.endsWith(".html")) for (const [, json] of copy.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)) {
    try { JSON.parse(json); expect(true, `${filename}: valid structured data`); }
    catch { expect(false, `${filename}: valid structured data`); }
  }
}
const llms = readFileSync(new URL("../public/llms.txt", import.meta.url), "utf8");
expect(llms.includes("optional paid AI Aerial opening") && llms.includes("reviewed original front exterior photo")
  && llms.includes("remaining Aerial allowance") && llms.includes("available processing capacity")
  && llms.includes("separate processor permission") && llms.includes("older free-form generator remains closed"),
  "llms.txt qualifies the scoped paid Aerial opening and closed legacy generator");
for (const filename of ["index.html", "support.html"]) {
  const copy=readFileSync(new URL(`../public/${filename}`, import.meta.url),"utf8");
  expect(copy.includes("separate permission before") && copy.includes("Kie"), `${filename}: optional Kie processing asks separately`);
  expect(!copy.includes("delete your account and everything in it"), `${filename}: no universal deletion promise`);
}
const publicAerial = Object.fromEntries(["features", "pricing", "support"].map((name) => [
  name, readFileSync(new URL(`../public/${name}.html`, import.meta.url), "utf8")
]));
for (const [name, html] of Object.entries(publicAerial)) {
  expect(!/Aerial (?:intros?|creation)[^<.\n]{0,100}(?:Coming soon|not included in any plan)/i.test(html),
    `${name}: no obsolete Aerial availability claim`);
  const json = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1];
  try { JSON.parse(json); expect(true, `${name}: parseable structured data`); }
  catch { expect(false, `${name}: parseable structured data`); }
}
const aerialSection = publicAerial.features.match(/<section id="aerials"[\s\S]*?<\/section>/)?.[0] || "";
expect(/reviewed original front exterior photo/.test(aerialSection) && /eligible paid access/.test(aerialSection)
  && /remaining Aerial allowance/.test(aerialSection) && /available processing capacity/.test(aerialSection)
  && /separate permission/.test(aerialSection) && /older free-form Aerial generator remains private and closed/.test(aerialSection)
  && /Previously saved or published/.test(aerialSection) && /Results vary; review/.test(aerialSection),
  "Features section describes scoped paid Aerial gate, variable results, and saved legacy clips");
const featuresGraph = JSON.parse(publicAerial.features.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1] || "null");
expect(featuresGraph?.["@graph"]?.some((node) => node["@type"] === "ItemList" && node.itemListElement?.some((item) =>
  /paid AI Aerial opening.*reviewed original front exterior photo.*allowance.*capacity.*processor permission/i.test(item.name))),
  "Features structured list qualifies the new opening");
expect(/<p class="wrap center price-note">[\s\S]*?eligible paid access[\s\S]*?remaining Aerial allowance[\s\S]*?available processing capacity[\s\S]*?separate permission[\s\S]*?older free-form generator remains closed[\s\S]*?<\/p>/.test(publicAerial.pricing),
  "Pricing note shows paid Aerial admission conditions and closed legacy generator");
expect(/<span>Optional AI Aerial opening<\/span><b>Eligible paid access<\/b>/.test(publicAerial.pricing),
  "Pricing comparison does not sell Aerial creation as a general plan benefit");
const pricingGraph = JSON.parse(publicAerial.pricing.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1] || "null");
expect(pricingGraph?.["@graph"]?.some((node) => node["@type"] === "SoftwareApplication"
  && /paid AI Aerial opening.*eligible allowance.*available capacity.*separate processor permission/i.test(node.description)),
  "Pricing structured application description includes the same Aerial gates");
const disclosureAnswer = publicAerial.support.match(/<summary>How is AI-generated content disclosed\?<\/summary>([\s\S]*?)<\/details>/)?.[1] || "";
expect(/paid AI Aerial opening/.test(disclosureAnswer) && /not captured drone footage or 3D/.test(disclosureAnswer)
  && /quality is not\s+guaranteed/.test(disclosureAnswer) && /Previously saved or published/.test(disclosureAnswer)
  && /older free-form Aerial generator remains closed/.test(disclosureAnswer),
  "Support visible disclosure distinguishes the scoped opening and saved legacy clips");
const supportGraph = JSON.parse(publicAerial.support.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1] || "null");
expect(supportGraph?.["@graph"]?.some((node) => node["@type"] === "FAQPage" && node.mainEntity?.some((item) =>
  /paid AI Aerial opening.*quality is not guaranteed.*older free-form Aerial generator remains closed/i.test(item.acceptedAnswer?.text || ""))),
  "Support structured FAQ carries the generated-footage review and closed-legacy limits");
expect(p.includes("180 days") && p.includes("applicable retention settings") && !p.includes("short, fixed schedule"), "No invented universal backup/log retention period");
// E7 (O07): the routine MetricKit payload callback sends nothing, so the notice
// may not describe launch-time figures. The native source is the oracle: if the
// callback starts reporting again, this fails until the copy is revised.
expect(!/median launch time|launch histogram|launch-time figures such as/i.test(p), "No stale launch-time example in the diagnostics copy");
expect(p.includes("for a hang, how long it lasted") && p.includes("does not currently send launch-time figures"), "Diagnostics copy matches the shipped MetricKit callbacks (hang duration; no launch metrics)");
expect(p.includes("crash, hang, CPU or disk-write problem"), "Diagnostics copy names the four MetricKit diagnostic categories the app reports");
const crashReporter = readFileSync(new URL("../../../../apps/ios/Rendprop/Analytics/CrashReporter.swift", import.meta.url), "utf8");
const metricCallback = /func didReceive\(_ payloads: \[MXMetricPayload\]\) \{([\s\S]*?)\n    \}/.exec(crashReporter)?.[1] ?? null;
expect(metricCallback !== null && !/\b(report|Analytics\.track|medianMilliseconds)\s*\(/.test(metricCallback), "Native MXMetricPayload callback still reports no launch metrics (copy oracle)");
expect(/hangDuration/.test(crashReporter) && /cpuExceptionDiagnostics/.test(crashReporter) && /diskWriteExceptionDiagnostics/.test(crashReporter), "Native diagnostics still cover hang duration, CPU and disk-write categories");
expect(privacy.includes('aria-label="Service providers and data processing"'), "Responsive table keeps a descriptive name");
expect((privacy.match(/role="row"/g) || []).length === 15, "All header/provider rows retain explicit roles");
expect((privacy.match(/role="cell"/g) || []).length === 42, "All provider cells retain explicit roles");
expect((privacy.match(/scope="col"/g) || []).length === 3, "All table headers retain column scope");
const processorCopy = JSON.parse(readFileSync(new URL("../../../../packages/client-contracts/property-video-processor-disclosure.json", import.meta.url), "utf8"));
expect(processorCopy.token === "property-video-jobs-v2" && processorCopy.processors?.length === 1 && processorCopy.processors[0] === "kie", "Supplementary permission is scoped to Kie v2, not earlier AI consent");
expect(typeof processorCopy.title === "string" && typeof processorCopy.body === "string" && createHash("sha256").update(`${processorCopy.title}\n\n${processorCopy.body}`, "utf8").digest("hex") === processorCopy.copy_sha256, "Native and Studio source copy has a reproducible exact-text digest");
expect(processorCopy.privacy_url === "https://rendprop.com/privacy" && processorCopy.provider_terms_url === "https://kie.ai/terms-of-use", "Client permission links to Rendprop privacy and the disclosed provider terms");
expect(processorCopy.body.includes("photos you select") && processorCopy.body.includes("camera-motion instructions") && processorCopy.body.includes("operate and improve") && processorCopy.body.includes("do not expressly rule out AI model training"), "Compact client notice covers selected inputs and provider-use uncertainty");
if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join("\n"));
  console.error(`Legal-page check: ${assertions} assertions, ${failures.length} failed, 0 skipped`);
  process.exit(1);
}
console.log(`Legal-page check: ${assertions} assertions, 0 failed, 0 skipped; actual emitted HTML, no provider calls`);
