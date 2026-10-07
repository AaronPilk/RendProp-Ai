import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { decodeServingActivation, decodeTrialOffer, decodeTrialUsage } from "../src/data/trial";
import { decodeWorkspace, type Membership } from "../src/data/contracts";
import TrialAllowance from "../src/features/business/TrialAllowance";
import { decodeAccount, notificationLabels, serviceActivationPending } from "../src/features/business/model";

const USER = "11111111-1111-4111-8111-111111111111";
const ORG = "33333333-3333-4333-8333-333333333333";
const memberships: Membership[] = [{ orgId: ORG, role: "owner", orgName: "Trial account", spaceType: "real_estate" }];
function trial() {
  return {
    org_id: ORG, status: "active", starts_at: "2026-10-29T12:00:00Z", ends_at: "2026-11-05T12:00:00Z",
    walkthroughs: { used: 1, cap: 1, remaining: 0 }, photo_edits: { used: 2, cap: 5, remaining: 3 },
    published_listings: { used: 0, cap: 1, remaining: 1 }, upload_budget_bytes: 1_073_741_824, upload_used_bytes: 100,
  };
}
function workspace() {
  return {
    user: { id: USER }, org: { id: ORG, name: "Trial account", handle: null, space_type: "real_estate" },
    plan: "pro", plan_raw: "pro", trial_ends_at: null, usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 },
  };
}
function account() {
  const features = ["renders", "photo_edits", "reels", "aerials", "drone"];
  return { ...workspace(), plan_source: "apple", plan_expires_at: "2026-12-05T12:00:00Z", trial_usage: null,
    notifications: { ...Object.fromEntries(Object.keys(notificationLabels).map((key) => [key, true])), muted_until: null },
    entitlement: { degraded: false }, usage: { by_feature: Object.fromEntries(features.map((key) => [key, 1])),
      caps: Object.fromEntries(features.map((key) => [key, 20])), windows: Object.fromEntries(features.map((key) => [key, null])) } };
}
const authorityPairs = [
  ["private_sponsorship", true, false], ["app_review", true, true], ["brokerage", true, false],
  ["existing_non_apple", true, false], ["verified_retail", true, true], ["funded_trial", true, true],
  ["subscription_activation_unavailable", false, false],
] as const;

test("serving activation decodes all seven exact workspace-bound authorities and absent legacy responses", () => {
  assert.equal(decodeServingActivation(undefined, ORG), null);
  assert.equal(decodeWorkspace(workspace(), USER, memberships).servingActivation, null);
  for (const [authority, available, funded] of authorityPairs) {
    const activation = { org_id: ORG, authority, available, funded };
    assert.deepEqual(decodeServingActivation(activation, ORG), { orgId: ORG, authority, available, funded });
  }
});
test("present service activation refuses wrong workspace, malformed fields and every contradictory pair", () => {
  for (const [authority, available, funded] of authorityPairs) for (const bad of [
    { org_id: ORG, authority, available: !available, funded },
    { org_id: ORG, authority, available, funded: !funded },
    { org_id: ORG, authority, available: String(available), funded },
    { org_id: ORG, authority, available, funded: Number(funded) },
  ]) assert.throws(() => decodeServingActivation(bad, ORG), /activation could not be verified/);
  for (const bad of [null, [], true, {}, { org_id: ORG, available: true, funded: true, authority: "unrecognized" },
    { org_id: ORG, available: true, funded: true, authority: "__proto__" }]) {
    assert.throws(() => decodeServingActivation(bad, ORG));
  }
  const foreign = { org_id: USER, authority: "verified_retail", available: true, funded: true };
  assert.throws(() => decodeWorkspace({ ...workspace(), serving_activation: foreign }, USER, memberships), /different workspace/);
  assert.throws(() => decodeAccount({ ...account(), serving_activation: foreign }, decodeWorkspace(workspace(), USER, memberships)), /different workspace/);
});
test("pending service suppresses paid caps while retaining signed plan and history; fresh retail response restores paid meters", () => {
  const selected = decodeWorkspace(workspace(), USER, memberships);
  const activation = { org_id: ORG, authority: "subscription_activation_unavailable", available: false, funded: false };
  const pending = decodeAccount({ ...account(), serving_activation: activation }, selected);
  assert.equal(pending.plan, "pro"); assert.equal(pending.planExpiresAt, "2026-12-05T12:00:00Z");
  assert.equal(pending.degraded, true); assert(pending.meters.every((meter) => meter.cap === 0 && meter.used === 1));
  const now = Date.parse("2026-11-05T12:00:00Z");
  assert.equal(serviceActivationPending(pending, now), true);
  assert.equal(serviceActivationPending({ ...pending, plan: "starter" }, now), true);
  for (const history of [{ ...pending, plan: "free", trialUsage: null }, { ...pending, planExpiresAt: "2026-11-01T12:00:00Z" }, { ...pending, planExpiresAt: null }, { ...pending, planSource: "manual" }]) assert.equal(serviceActivationPending(history, now), false);
  const pendingWorkspace = decodeWorkspace({ ...workspace(), serving_activation: activation }, USER, memberships);
  assert.equal(pendingWorkspace.plan, "pro"); assert.equal(pendingWorkspace.planDegraded, true);
  const expired = decodeAccount({ ...account(), plan: "free", trial_usage: { ...trial(), status: "expired" }, serving_activation: activation }, selected);
  assert.equal(expired.trialUsage?.status, "expired"); assert.equal(expired.plan, "free");
  assert.equal(serviceActivationPending(expired, now), false);
  const exhausted = decodeAccount({ ...account(), trial_usage: { ...trial(), status: "exhausted" }, serving_activation: activation }, selected);
  assert.equal(serviceActivationPending(exhausted, now), false);
  const recordedActive = decodeAccount({ ...account(), plan_expires_at: null, trial_usage: trial(), serving_activation: activation }, selected);
  assert.equal(serviceActivationPending(recordedActive, now), true);
  assert.equal(recordedActive.trialUsage?.photoEdits.remaining, 3);
  assert(recordedActive.meters.every((meter) => meter.cap === 0));
  const paid = decodeAccount({ ...account(), trial_usage: null, serving_activation: { ...activation, authority: "verified_retail", available: true, funded: true } }, selected);
  assert.equal(paid.degraded, false); assert.equal(paid.trialUsage, null); assert(paid.meters.every((meter) => meter.cap === 20));
  assert.equal(decodeAccount(account(), selected).servingActivation, null);
});

test("old /me responses do not manufacture a trial from the chosen plan", () => {
  const old = decodeWorkspace(workspace(), USER, memberships);
  assert.equal(old.trialUsage, null);
  assert.equal(old.trialOffer, null);
  assert.equal(decodeTrialUsage(null, ORG), null);
});
test("signed seven-day trial crossing month-end retains three independent counters", () => {
  const decoded = decodeWorkspace({ ...workspace(), trial_usage: trial() }, USER, memberships);
  assert.equal(decoded.trialUsage?.endsAt, "2026-11-05T12:00:00Z");
  assert.equal(decoded.trialUsage?.walkthroughs.remaining, 0);
  assert.equal(decoded.trialUsage?.photoEdits.remaining, 3);
  assert.equal(decoded.trialUsage?.publishedListings.remaining, 1);
});
test("a different workspace trial cannot be attached to the current account", () => {
  assert.throws(() => decodeWorkspace({ ...workspace(), trial_usage: { ...trial(), org_id: USER } }, USER, memberships), /different workspace/);
});
test("malformed trial counters and windows are refused instead of offering additional usage", () => {
  for (const value of [
    { ...trial(), status: "paid" },
    { ...trial(), ends_at: "2026-11-06T12:00:00Z" },
    { ...trial(), ends_at: trial().starts_at },
    { ...trial(), starts_at: "not-a-date" },
    { ...trial(), starts_at: "2026-10-29T12:00:00" },
    { ...trial(), photo_edits: { used: 2, cap: 5, remaining: 5 } },
    { ...trial(), photo_edits: { used: 6, cap: 5, remaining: 0 } },
    { ...trial(), photo_edits: { used: -1, cap: 5, remaining: 6 } },
    { ...trial(), photo_edits: { used: 2, cap: 5.5, remaining: 3.5 } },
    { ...trial(), upload_used_bytes: 1_073_741_825 },
    { ...trial(), upload_budget_bytes: 0 },
    { ...trial(), walkthroughs: [] },
    { ...trial(), walkthroughs: { used: 0, cap: 2, remaining: 2 } },
    { ...trial(), photo_edits: { used: 0, cap: 6, remaining: 6 } },
    { ...trial(), published_listings: { used: 0, cap: 2, remaining: 2 } },
    { ...trial(), upload_budget_bytes: 1_073_741_825 },
  ]) assert.throws(() => decodeTrialUsage(value, ORG), /allowance could not be verified/);
});
test("refreshing the account uses fresh trial usage rather than the workspace's earlier snapshot", () => {
  const selected = decodeWorkspace({ ...workspace(), trial_usage: trial() }, USER, memberships);
  const features = ["renders", "photo_edits", "reels", "aerials", "drone"];
  const body = {
    ...workspace(), trial_usage: { ...trial(), photo_edits: { used: 4, cap: 5, remaining: 1 } },
    notifications: { ...Object.fromEntries(Object.keys(notificationLabels).map((key) => [key, true])), muted_until: null },
    entitlement: { degraded: false },
    usage: { by_feature: Object.fromEntries(features.map((key) => [key, 0])), caps: Object.fromEntries(features.map((key) => [key, 0])), windows: Object.fromEntries(features.map((key) => [key, null])) },
  };
  assert.equal(selected.trialUsage?.photoEdits.remaining, 3);
  assert.equal(decodeAccount(body, selected).trialUsage?.photoEdits.remaining, 1);
  const renewed = decodeAccount({ ...body, plan: "team", plan_expires_at: "2026-12-05T12:00:00Z", trial_ends_at: null, trial_usage: null }, selected);
  assert.equal(renewed.plan, "team");
  assert.equal(renewed.planExpiresAt, "2026-12-05T12:00:00Z");
  assert.equal(renewed.trialEndsAt, null);
  assert.equal(renewed.trialUsage, null);
  for (const degraded of ["true", 1, null]) assert.throws(() => decodeAccount({ ...body, entitlement: { degraded } }, selected), /setting/);
  assert.throws(() => decodeAccount({ ...body, trial_usage: { ...trial(), org_id: USER } }, selected), /different workspace/);
});
test("dormant offer never displays proposed caps; enabled offers require verified quantities", () => {
  assert.equal(decodeTrialOffer({ enabled: false, photo_edits: 1000 }), null);
  const offer = { enabled: true, walkthroughs: 1, photo_edits: 5, published_listings: 1, max_days: 7, max_video_seconds: 90, upload_budget_bytes: 1_073_741_824 };
  assert.equal(decodeTrialOffer(offer)?.photoEdits, 5);
  for (const value of [{ ...offer, enabled: "true" }, { ...offer, max_days: 8 }, { ...offer, walkthroughs: 0 }, { ...offer, photo_edits: -1 }, { ...offer, max_video_seconds: undefined }, { ...offer, walkthroughs: 2 }, { ...offer, photo_edits: 6 }, { ...offer, published_listings: 2 }, { ...offer, max_video_seconds: 91 }, { ...offer, upload_budget_bytes: 1_073_741_825 }]) {
    assert.throws(() => decodeTrialOffer(value), /allowance could not be verified/);
  }
});
test("active trial view preserves remaining photo and publication steps after walkthrough is used", () => {
  const html = renderToStaticMarkup(createElement(TrialAllowance, { trial: decodeTrialUsage(trial(), ORG)! }));
  assert.match(html, /3 remaining/);
  assert.match(html, /1 remaining/);
  assert.match(html, /Upload space/);
  assert.match(html, /including files still uploading/);
  assert.match(html, /access and retention terms/);
  assert.match(html, /They do not reset during the trial/);
  assert.match(html, /does not bring Apple/);
  assert.doesNotMatch(html, /Resets|Monthly|unlimited|100 AI/);
});
test("exhausted and expired views keep saved-work access and explicit subscription management", () => {
  for (const status of ["exhausted", "expired"]) {
    const decoded = decodeTrialUsage({ ...trial(), status }, ORG)!;
    const html = renderToStaticMarkup(createElement(TrialAllowance, { trial: decoded }));
    assert.match(html, /saved photos, videos and downloads remain accessible/);
    assert.match(html, /apps.apple.com\/account\/subscriptions/);
    assert.match(html, status === "expired" ? /creation window has ended/ : /included trial allowance/);
    assert.doesNotMatch(html, /charged now|delete your/);
  }
});
test("full upload allowance leaves photo and publication counters visible for existing media", () => {
  const decoded = decodeTrialUsage({ ...trial(), upload_used_bytes: 1_073_741_824 }, ORG)!;
  const html = renderToStaticMarkup(createElement(TrialAllowance, { trial: decoded }));
  assert.match(html, /0 MB remaining/);
  assert.match(html, /3 remaining/);
  assert.match(html, /1 remaining/);
  assert.doesNotMatch(html, /creation window has ended|used your included trial allowance/);
});
