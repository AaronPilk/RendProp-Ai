import test from "node:test";
import assert from "node:assert/strict";
import type { Workspace } from "../src/data/contracts";
import type { StudioServices } from "../src/data/services";
import { businessApi } from "../src/features/business/api";
import { brandPayload, canEditLeads, canRemoveMember, contactLink, csv, decodeAccount, decodeCompliance, decodeInviteResults, decodeLeads, decodeNotifications, decodeTeam, filterLeads, inviteEmails, safeHTTPS, type Brand } from "../src/features/business/model";

const user = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", listing = "33333333-3333-4333-8333-333333333333", id = "44444444-4444-4444-8444-444444444444";
const workspace: Workspace = { user: { id: user, email: "agent@example.invalid", name: "Agent", avatarUrl: null }, org: { id: org, name: "Office", handle: "office", spaceType: "real_estate" }, memberships: [{ orgId: org, orgName: "Office", role: "owner", spaceType: "real_estate" }], plan: "team", planRaw: "team", planDegraded: false, planExpiresAt: null, trialEndsAt: null, usage: { listings: 1, leads: 1, leadsNew: 1, renders: 1 } };
const wireLead = { id, listing_id: listing, name: "Alex", email: "alex@example.invalid", phone: "+1 555 111 2222", message: "Can I see the garden?", listing_address: "10 Oak Street", source: "tour", status: "new", synced_crm: false, created_at: "2026-09-14T12:00:00Z" };
const prefs = { lead_received: true, render_ready: true, upload_stuck: false, free_week_ending: true, allowance_low: true, first_tour_nudge: false, muted_until: null };
const brand: Brand = { org_name: "Office", handle: "office", space_type: "real_estate", name: "Agent", title: "REALTOR", brokerage: "Office", phone: "", email: "", website: "https://example.invalid", avatar_url: "", headshot_url: "", instagram: "", linkedin: "", tiktok: "", accent: "#7c3aed" };
const meter = { renders: 1, photo_edits: 2, reels: 3, aerials: 4, drone: 5 };
const me = { user: { id: user }, org: { id: org, name: "Office", handle: "office", space_type: "real_estate", brand_kit: {} }, usage: { by_feature: meter, caps: meter, windows: Object.fromEntries(Object.keys(meter).map((k) => [k, null])) }, notifications: prefs, entitlement: {}, portfolio_url: "https://rendprop.com/a/office", plan_source: "apple" };

test("leads decode native response and search contact, listing and message", () => {
  const leads = decodeLeads({ leads: [wireLead] });
  assert.equal(leads[0].listingId, listing);
  for (const q of ["alex", "OAK", " garden ", "555"]) assert.equal(filterLeads(leads, q).length, 1);
  assert.equal(filterLeads(leads, "missing").length, 0);
  assert.equal(filterLeads(leads, "").length, 1);
});
test("lead decoder rejects duplicate IDs, unknown statuses and oversized pages", () => {
  assert.throws(() => decodeLeads({ leads: [wireLead, wireLead] }), /duplicate/);
  assert.throws(() => decodeLeads({ leads: [{ ...wireLead, status: "pending" }] }), /status/);
  assert.throws(() => decodeLeads({ leads: Array(501).fill(wireLead) }), /list/);
});
test("workspace and user identity are checked on account hydration", () => {
  assert.equal(decodeAccount(me, workspace).meters.length, 5);
  assert.throws(() => decodeAccount({ ...me, org: { ...me.org, id: listing } }, workspace), /account changed/);
  assert.throws(() => decodeAccount({ ...me, user: { id } }, workspace), /account changed/);
  assert.equal(decodeAccount({ ...me, entitlement: { degraded: true } }, workspace).degraded, true);
});
test("notification switches preserve false values and exact mute timestamps", () => {
  const expected = { ...prefs, muted_until: "2026-09-15T12:00:00Z" };
  assert.deepEqual(decodeNotifications(expected), expected);
  assert.throws(() => decodeNotifications({ ...prefs, upload_stuck: "false" }), /setting/);
  assert.throws(() => decodeNotifications({ ...prefs, muted_until: "tomorrow" }), /date/);
});
test("brand updates whitelist native editable fields and cannot alter entitlement", () => {
  const payload = brandPayload({ ...brand, plan: "enterprise", role: "owner" } as Brand);
  assert.equal(payload.org_name, "Office"); assert.equal(payload.avatar_url, null);
  assert.equal("plan" in payload, false); assert.equal("role" in payload, false);
  assert.throws(() => brandPayload({ ...brand, website: "javascript:alert(1)" }), /https/);
  assert.throws(() => brandPayload({ ...brand, handle: "bad/name" }), /Portfolio/);
  assert.throws(() => brandPayload({ ...brand, accent: "red" }), /color/);
  assert.throws(() => brandPayload({ ...brand, space_type: "fake" }), /business type/);
});
test("existing iPhone brand domains and social handles stay editable in Studio", () => {
  const payload = brandPayload({ ...brand, website: "agent.example.invalid", instagram: "@sarah.agent", linkedin: "linkedin.com/in/sarah", tiktok: "@sarah" });
  assert.equal(payload.website, "https://agent.example.invalid");
  assert.equal(payload.instagram, "https://instagram.com/sarah.agent");
  assert.equal(payload.linkedin, "https://linkedin.com/in/sarah");
  assert.equal(payload.tiktok, "https://tiktok.com/@sarah");
});
test("team decoder fences the workspace and withholds invites for non-managers", () => {
  const value = { org_id: org, can_manage: false, seats: { used: 1, allowed: 2 }, members: [{ user_id: user, role: "agent", name: null, email: null, is_you: true }], invites: [{ code: "must-not-appear" }] };
  assert.deepEqual(decodeTeam(value, org).invites, []);
  assert.throws(() => decodeTeam(value, id), /different workspace/);
});
test("member removal and lead controls mirror backend role restrictions", () => {
  const admin = { id, name: "Admin", email: "", role: "admin" as const, isYou: false };
  assert.equal(canRemoveMember("owner", admin), true);
  assert.equal(canRemoveMember("admin", admin), false);
  assert.equal(canRemoveMember("owner", { ...admin, role: "owner" }), false);
  assert.equal(canRemoveMember("owner", { ...admin, isYou: true }), false);
  assert.equal(canRemoveMember("marketing", { ...admin, role: "agent" }), false);
  assert.equal(canEditLeads("marketing"), false); assert.equal(canEditLeads("agent"), true);
});
test("invite forms validate and deduplicate without silently dropping malformed recipients", () => {
  assert.deepEqual(inviteEmails("A@example.invalid, b@example.invalid\nA@example.invalid"), ["a@example.invalid", "b@example.invalid"]);
  assert.deepEqual(inviteEmails(""), []);
  assert.throws(() => inviteEmails("valid@example.invalid, bad"), /Check/);
  assert.throws(() => inviteEmails(Array(201).fill("a@example.invalid").join(",")), /200/);
  assert.equal(decodeInviteResults({ code: "ABCD-EFGH-JKLM", email: "a@example.invalid", expires_at: "2026-09-21T00:00:00Z" }, false)[0].code, "ABCD-EFGH-JKLM");
  assert.throws(() => decodeInviteResults({ code: "bad" }, false), /created/);
});
test("disclosures preserve original availability and refuse malformed counts and cross-workspace reports", () => {
  const row = { id, listing_id: listing, created_at: "2026-09-14T00:00:00Z", kind: "photo", disclosure: "AI altered", original_available: false, original_url: "javascript:bad", altered_url: "https://media.example.invalid/result" };
  const report = { org_id: org, count: 1, rows: [row], truncated: true };
  const result = decodeCompliance(report, org);
  assert.equal(result.rows[0].originalUrl, null); assert.equal(result.truncated, true);
  assert.throws(() => decodeCompliance({ ...report, count: 2 }, org), /incomplete/);
  assert.throws(() => decodeCompliance(report, id), /different workspace/);
});
test("exports neutralize spreadsheet formulas, preserve multiline text and escape quotes", () => {
  const output = csv([["=SUM(A1)", " \t+cmd", "@thing", "-123", "hello\nthere", 'say "hello"']]);
  assert.ok(output.startsWith("\ufeff"));
  assert.ok(output.includes('"\'=SUM(A1)"')); assert.ok(output.includes('"\' \t+cmd"'));
  assert.ok(output.includes('"hello\nthere"')); assert.ok(output.includes('"say ""hello"""'));
});
test("contact and external links reject injected schemes and mail headers", () => {
  assert.equal(contactLink("email", "a@example.invalid?bcc=leak"), null);
  assert.equal(contactLink("phone", "123;ext=bad"), null);
  assert.equal(contactLink("phone", "+1 (555) 111-2222"), "tel:+15551112222");
  assert.equal(safeHTTPS("https://user:pass@example.invalid"), null);
  assert.equal(safeHTTPS("javascript:bad"), null);
});
test("business operations carry selected org and exact native routes without mutation retries", async () => {
  const calls: { path: string; options: Parameters<StudioServices["api"]>[1] }[] = [];
  const services = { api: async (path: string, options: Parameters<StudioServices["api"]>[1]) => {
    calls.push({ path, options });
    if (path.includes("leads/")) return { lead: { ...wireLead, status: "contacted" } };
    if (path.includes("leads?")) return { leads: [wireLead] };
    if (path.includes("invites")) return { code: "ABCD-EFGH-JKLM" };
    if (path.endsWith("notifications")) return { notifications: prefs };
    return { ok: true };
  } };
  const api = businessApi(services, workspace);
  const controller = new AbortController();
  await api.leads({ listingId: listing, status: "new", since: "2026-09-01" }, controller.signal);
  await api.setLeadStatus(id, "contacted", controller.signal);
  await api.invite("", "agent", controller.signal);
  await api.saveBrand(brand, controller.signal);
  await api.saveNotifications(prefs, controller.signal);
  assert.equal(calls.length, 5);
  for (const c of calls) { assert.equal(c.options.orgId, org); assert.equal(c.options.signal, controller.signal); }
  assert.match(calls[0].path, /listing_id=33333333/);
  assert.equal(calls[1].path, `/functions/v1/leads/${id}`); assert.equal(calls[1].options.method, "PATCH");
  assert.deepEqual(calls[2].options.body, { role: "agent" });
  assert.equal(calls[3].path, "/functions/v1/me/brand");
  assert.deepEqual(calls[4].options.body, prefs);
});
test("failed invitations and deletion cannot be silently retried", async () => {
  let calls = 0;
  const api = businessApi({ api: async () => { calls++; throw new Error("Connection lost"); } }, workspace);
  await assert.rejects(api.invite("agent@example.invalid", "agent"), /Connection lost/);
  assert.equal(calls, 1);
  await assert.rejects(api.deleteAccount("DELETE"), /Type DELETE/); assert.equal(calls, 1);
  await assert.rejects(api.deleteAccount("DELETE MY ACCOUNT"), /Connection lost/); assert.equal(calls, 2);
  await assert.rejects(api.invite("", "owner"), /role/); assert.equal(calls, 2);
});
