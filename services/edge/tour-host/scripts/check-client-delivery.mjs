#!/usr/bin/env node
// Exercise the actual public renderer. Only synthetic contacts; no network.
import assert from "node:assert/strict";
import vm from "node:vm";
import { buildSrc } from "./build-src.mjs";
const load = buildSrc("client-delivery-check");
const { renderTourPage, unbrandedSelfCheck } = await load("player");
const { buildDemoTour } = await load("demo");
const source = buildDemoTour();
source.agent_card = { name: "Synthetic Client Alpha", phone: "555-010-1000", email: "alpha@example.invalid", brokerage: "Synthetic Client Brokerage", avatar_url: "https://media.invalid/client-alpha.jpg", handle: "photographer-private-portfolio" };
source.cta = { mode: "lead_form", label: "Contact agent", url: null, secondary: [], lead_fields: ["name", "phone", "message"] };
source.altered_media = [{ label: "Synthetic room", kind: "declutter", disclosure: "Objects were digitally removed.", original_url: "https://media.invalid/original.jpg", altered_url: "https://media.invalid/declutter.jpg" }];
source.listing = { ...source.listing, details: { ...source.listing.details, show_partners: true, show_financing: true, show_app_cta: true } };
const render = (tour, opts = {}) => renderTourPage(tour, "https://functions.invalid/v1", "synthetic-anon", "", opts);
const baseline = render(source);
assert.equal(render({ ...source, client_mode: false, hide_rendprop_branding: false }), baseline, "Absent flags and explicit legacy false preserve identical output");
for (const flags of [{ hide_rendprop_branding: true }, { client_mode: true }, { client_mode: true, hide_rendprop_branding: false }, { client_mode: "true", hide_rendprop_branding: true }, { client_mode: true, hide_rendprop_branding: "true" }]) {
  const html = render({ ...source, ...flags });
  assert.match(html, /lp-madeby/, "Only two explicit boolean flags suppress promotions");
  assert.match(html, /apple-itunes-app/);
}
const hidden = { ...source, client_mode: true, hide_rendprop_branding: true };
for (const opts of [{}, { embed: true }]) {
  const html = render(hidden, opts);
  assert.doesNotMatch(html, /id="(?:getapp|brand|wm)"|class="lp-madeby"|class="lp-partner"|name="apple-itunes-app"|href="\/favicon\.svg"|class="mark">RENDPROP| — Rendprop<\/title>|rp_wanted_tour/);
  assert.doesNotMatch(html, /photographer-private-portfolio|Pilk\.ai|Promoted by Rendprop|Lender promotion from Rendprop/);
  for (const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
  if (!opts.embed) {
    assert.match(html, /Synthetic Client Alpha/);
    assert.match(html, /media\.invalid\/client-alpha\.jpg/);
    assert.match(html, /mailto:alpha@example\.invalid/);
    assert.match(html, /id="leadform"/);
    assert.match(html, /photographer or video producer managing this listing/);
    assert.match(html, /href="\/privacy"/);
    assert.match(html, /Objects were digitally removed\./);
    assert.match(html, /href="https:\/\/media\.invalid\/original\.jpg"/);
    assert.match(html, /preload="none"/);
  }
}
const retained = render({ ...hidden, hide_rendprop_branding: false });
assert.doesNotMatch(retained, /photographer-private-portfolio/, "Client pages never advertise the photographer's portfolio, even with vendor promotions enabled");
assert.match(retained, /lp-madeby/);
const ownLender = render({ ...hidden, listing: { ...hidden.listing, details: { ...hidden.listing.details, lender_name: "Synthetic Client Lender", lender_url: "https://client-lender.invalid" } } });
assert.match(ownLender, /Synthetic Client Lender/, "Client's own explicit lender survives promotion suppression");
const beta = render({ ...hidden, agent_card: { ...hidden.agent_card, name: "Synthetic Client Beta", email: "beta@example.invalid", avatar_url: "https://media.invalid/client-beta.jpg" } });
assert.match(beta, /Synthetic Client Beta/);
assert.doesNotMatch(beta, /Synthetic Client Alpha|alpha@example\.invalid|client-alpha\.jpg/, "Different listings never inherit another client's identity");
const escaped = render({ ...hidden, agent_card: { ...hidden.agent_card, name: '<img src=x onerror="alert(1)">' } });
assert.doesNotMatch(escaped, /<img src=x onerror=/);
for (const tour of [source, hidden]) {
  const html = render(tour, { unbranded: true });
  assert.deepEqual(unbrandedSelfCheck(html, tour), []);
  assert.doesNotMatch(html, /id="leadform"|Synthetic Client Alpha|alpha@example\.invalid|client-alpha\.jpg/);
}
console.log("Client delivery: legacy compatibility, strict branding flags, isolated cards, disclosure, opt-in video and MLS stripping passed.");
