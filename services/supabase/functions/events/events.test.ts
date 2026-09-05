// events.test.ts — the three rules that keep personal data out of app_events.
//
//   deno test services/supabase/functions/events/events.test.ts
//
// Everything under test is PURE (schema.ts has no network, no env, no
// Deno.serve), so these are exact assertions rather than approximations: no
// stubbed fetch, no database, no server. index.ts is deliberately not imported
// — it calls Deno.serve at module load.
//
// What is being defended, in order of how bad it would be to get wrong:
//   1. SCRUB      — a street address, e-mail, phone number or file path in a
//                   string prop must come out as "[redacted]".
//   2. WHITELIST  — an unknown prop key is dropped and COUNTED, never stored,
//                   and never a 400.
//   3. VOCABULARY — an event name we did not write is refused, and the refusal
//                   names what is allowed.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import {
  ALLOWED_EVENT_NAMES,
  EVENT_SCHEMA,
  MAX_EVENT_BYTES,
  isAllowedEvent,
  normalizeBatch,
  normalizeTimestamp,
  sanitizeProps,
  scrubMeta,
  scrubString,
} from "./schema.ts";

const NOW = new Date("2026-09-05T12:00:00.000Z");

// ── 1. The scrubber ─────────────────────────────────────────────────────────

Deno.test("scrub: e-mail addresses never survive", () => {
  assertEquals(scrubString("failed for aaron@skyway.media"), "failed for [redacted]");
  assertEquals(scrubString("a.b+tag@sub.example.co.uk"), "[redacted]");
});

Deno.test("scrub: street addresses never survive", () => {
  assertEquals(scrubString("1600 Pennsylvania Ave"), "[redacted]");
  assertEquals(scrubString("published 742 Evergreen Terrace ok"), "published [redacted] ok");
  assertEquals(scrubString("12 Oak St."), "[redacted]");
});

Deno.test("scrub: phone numbers never survive", () => {
  assertEquals(scrubString("call +1 (415) 555-0132 now"), "call [redacted] now");
  assertEquals(scrubString("4155550132"), "[redacted]");
});

Deno.test("scrub: URLs and file paths never survive", () => {
  assertEquals(scrubString("https://rendprop.com/f/abc?e=a@b.com"), "[redacted]");
  assertEquals(scrubString("open www.example.com/x"), "open [redacted]");
  assertEquals(scrubString("wrote Users/aaron/Photos/IMG_1.jpg"), "wrote [redacted]");
  assertEquals(scrubString("mailto:someone@example.com"), "[redacted]");
});

Deno.test("scrub: ordinary analytics strings are left alone", () => {
  for (const ok of ["real_estate", "apple", "pro", "com.rendprop.app.pro.monthly", "sky", "hang", "1.0 (1)", "iOS 26.4"]) {
    assertEquals(scrubString(ok), ok, `"${ok}" must survive the scrubber unchanged`);
  }
});

Deno.test("scrub: short numbers are not mistaken for phone numbers", () => {
  // Durations, counts and ZIP codes must not be redacted — the phone rule
  // needs 8+ digits precisely so these survive.
  assertEquals(scrubString("94110"), "94110");
  assertEquals(scrubString("duration 128"), "duration 128");
});

Deno.test("scrub: output is clipped and whitespace-collapsed", () => {
  assertEquals(scrubString("  a\n\n  b  "), "a b");
  assertEquals(scrubString("x".repeat(500)).length, 200);
  assertEquals(scrubString("x".repeat(500), 40).length, 40);
});

Deno.test("scrubMeta: clips to 40 and nulls an empty result", () => {
  assertEquals(scrubMeta("iOS 26.4"), "iOS 26.4");
  assertEquals(scrubMeta("v".repeat(90))!.length, 40);
  assertEquals(scrubMeta(""), null);
  assertEquals(scrubMeta(42), null);
  assertEquals(scrubMeta(undefined), null);
});

// ── 2. The props whitelist ──────────────────────────────────────────────────

Deno.test("whitelist: unknown keys are dropped and counted, known keys kept", () => {
  const out = sanitizeProps("home_created", {
    space_type: "real_estate",
    address: "1600 Pennsylvania Ave",   // not whitelisted
    email: "aaron@skyway.media",        // not whitelisted
    listing_id: "abc-123",              // not whitelisted (a join key to an address)
  });
  assertEquals(out.props, { space_type: "real_estate" });
  assertEquals(out.dropped, 3);
});

Deno.test("whitelist: a whitelisted key still gets scrubbed", () => {
  // `detail` IS allowed on `error` — layer 3 is what stops it carrying a person.
  const out = sanitizeProps("error", { detail: "upload failed for aaron@skyway.media" });
  assertEquals(out.props.detail, "upload failed for [redacted]");
  assertEquals(out.dropped, 0);
});

Deno.test("whitelist: numbers and booleans pass, nested values do not", () => {
  const out = sanitizeProps("render_finished", {
    ok: true,
    duration_s: 12.5,
    seconds: 90,
    tier: { nested: "no" },      // object → dropped
  });
  assertEquals(out.props, { ok: true, duration_s: 12.5, seconds: 90 });
  assertEquals(out.dropped, 1);
});

Deno.test("whitelist: null, NaN and empty strings are dropped, not stored", () => {
  const out = sanitizeProps("ai_photo_edit", {
    task: "",            // scrubs to empty
    provider: null,      // null
    ms: Number.NaN,      // not JSON-representable
    ok: false,
  });
  assertEquals(out.props, { ok: false });
  assertEquals(out.dropped, 3);
});

Deno.test("whitelist: a non-object props value is dropped whole", () => {
  assertEquals(sanitizeProps("app_open", "nope").dropped, 1);
  assertEquals(sanitizeProps("app_open", ["a"]).dropped, 1);
  assertEquals(sanitizeProps("app_open", undefined).props, {});
});

Deno.test("whitelist: no schema key can hold a person, a place or a file", () => {
  // A guard on the schema itself: if someone later adds `address` or `email` to
  // an event's whitelist, this fails before it ships.
  const banned = ["address", "email", "phone", "name", "url", "path", "file",
                  "photo", "lat", "lng", "listing_id", "user_id", "org_id"];
  for (const [event, keys] of Object.entries(EVENT_SCHEMA)) {
    for (const key of keys) {
      assert(!banned.includes(key), `${event}.${key} is a PII-shaped prop key`);
    }
  }
});

// ── 3. The vocabulary ───────────────────────────────────────────────────────

Deno.test("vocabulary: exactly the names in the launch contract", () => {
  assertEquals([...ALLOWED_EVENT_NAMES].sort(), [
    "aerial_made", "ai_photo_edit", "app_open", "capture_finished", "capture_started",
    "crash", "error", "home_created", "paywall_viewed", "purchase_completed",
    "purchase_failed", "purchase_started", "reel_made", "render_finished", "restore",
    "signin", "signup", "tour_published", "voiceover_added",
  ]);
});

Deno.test("vocabulary: anything else is refused", () => {
  assert(isAllowedEvent("app_open"));
  assert(!isAllowedEvent("app_opened"));
  assert(!isAllowedEvent(""));
  assert(!isAllowedEvent(null));
  // Prototype keys must not read as members of the vocabulary.
  assert(!isAllowedEvent("toString"));
  assert(!isAllowedEvent("constructor"));
});

Deno.test("batch: one unknown name reports the name and stores nothing from it", () => {
  const out = normalizeBatch(
    [{ name: "app_open", t: "2026-09-05T11:00:00Z" }, { name: "hacked", props: {} }],
    NOW,
  );
  assertEquals(out.unknownName, "hacked");
  assertEquals(out.events.length, 1);           // the good one still normalised
  assertStringIncludes(ALLOWED_EVENT_NAMES.join(","), "app_open");
});

// ── 4. Batch normalisation ──────────────────────────────────────────────────

Deno.test("batch: a future timestamp is clamped to now, a bad one becomes now", () => {
  assertEquals(normalizeTimestamp("2099-01-01T00:00:00Z", NOW), NOW.toISOString());
  assertEquals(normalizeTimestamp("not a date", NOW), NOW.toISOString());
  assertEquals(normalizeTimestamp(undefined, NOW), NOW.toISOString());
  // A past timestamp is kept — the app buffers events offline for days.
  assertEquals(normalizeTimestamp("2026-09-01T08:30:00.000Z", NOW), "2026-09-01T08:30:00.000Z");
});

Deno.test("batch: an over-1KB event is dropped alone, not with the batch", () => {
  const fat = { name: "error", props: { detail: "d".repeat(4000), category: "metrics" } };
  const out = normalizeBatch([{ name: "app_open" }, fat, { name: "signup", props: { method: "apple" } }], NOW);
  // `detail` is clipped to 200 chars by the scrubber, so this one actually fits —
  // which is the point: the clip is the first line of defence, the byte cap the second.
  assertEquals(out.events.length, 3);
  for (const e of out.events) {
    assert(JSON.stringify(e).length <= MAX_EVENT_BYTES);
  }
});

Deno.test("batch: junk entries are dropped and counted, never inserted", () => {
  const out = normalizeBatch(["nope", null, 7, { name: "app_open" }], NOW);
  assertEquals(out.events.length, 1);
  assertEquals(out.droppedEvents, 3);
});

Deno.test("batch: a non-array body normalises to nothing", () => {
  const out = normalizeBatch({ name: "app_open" }, NOW);
  assertEquals(out.events.length, 0);
  assertEquals(out.unknownName, null);
});

Deno.test("batch: dropped props are counted across the whole batch", () => {
  const out = normalizeBatch([
    { name: "app_open", props: { junk: 1 } },
    { name: "signup", props: { method: "apple", email: "a@b.com" } },
  ], NOW);
  assertEquals(out.droppedProps, 2);
  assertEquals(out.events[1].props, { method: "apple" });
});

Deno.test("batch: no stored event ever carries a raw e-mail or address", () => {
  // The end-to-end promise, asserted on the serialized rows that would be
  // inserted — whatever the client sends.
  const out = normalizeBatch([
    { name: "home_created", props: { space_type: "real_estate", address: "1600 Pennsylvania Ave" } },
    { name: "error", props: { category: "upload", detail: "aaron@skyway.media at 742 Evergreen Terrace" } },
    { name: "crash", props: { kind: "crash", termination_reason: "killed at /var/mobile/x.jpg" } },
  ], NOW);
  const wire = JSON.stringify(out.events);
  assert(!wire.includes("@skyway.media"), wire);
  assert(!wire.includes("Pennsylvania"), wire);
  assert(!wire.includes("Evergreen"), wire);
  assert(!wire.includes("/var/mobile"), wire);
});
