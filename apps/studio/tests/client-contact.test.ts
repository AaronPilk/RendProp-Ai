import test from "node:test";
import assert from "node:assert/strict";
import { clientContactPayload, clientForm, decodeClientContact } from "../src/features/listings/client-contact";
import { decodeListingState } from "../src/features/listings/model";
import { validateUpload } from "../src/features/listings/uploads";
import { decodeRealEstateRole } from "../src/data/contracts";
const listing = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", photo = "33333333-3333-4333-8333-333333333333";
const contact = { listing_id: listing, enabled: true, public_card: { name: "Client Agent", email: "public@example.invalid", phone: "+1 555 111 2222", avatar_url: "https://media.invalid/client.jpg" }, recipient_email: "private@example.invalid", hide_rendprop_branding: true, photo_asset_id: photo, revision: 2, updated_at: "2026-10-01T12:00:00Z" };
test("per-listing client decoding binds identity and retains private delivery separately", () => {
  const parsed = decodeClientContact({ contact }, listing)!;
  assert.equal(parsed.recipient_email, "private@example.invalid"); assert.equal(parsed.public_card.email, "public@example.invalid");
  assert.equal(clientForm(parsed).separate_recipient, true); assert.equal(clientForm(null).enabled, false); assert.equal(clientForm(null).hide_rendprop_branding, true);
  assert.throws(() => decodeClientContact({ contact }, org), /another property/);
});
test("incomplete or unverified client responses block publishing", () => {
  for (const bad of [undefined, {}, { contact: { ...contact, enabled: "true" } }, { contact: { ...contact, revision: 0 } }, { contact: { ...contact, updated_at: "bad" } }, { contact: { ...contact, public_card: {} } }, { contact: { ...contact, recipient_email: "invalid" } }, { contact: { ...contact, public_card: { name: "Client", avatar_url: "javascript:alert(1)" } } }]) assert.throws(() => decodeClientContact(bad, listing));
  assert.equal(decodeClientContact({ contact: null }, listing), null);
});
test("save whitelists public contact fields and never sends a photographer portfolio handle or avatar URL", () => {
  const form = clientForm(decodeClientContact({ contact: { ...contact, public_card: { ...contact.public_card, handle: "photographer", plan: "team" } } }, listing));
  const payload = clientContactPayload(form, 2);
  assert.equal(payload.expected_revision, 2); assert.equal(payload.photo_asset_id, photo); assert.equal(payload.recipient_email, "private@example.invalid");
  assert.equal("handle" in payload.public_card, false); assert.equal("avatar_url" in payload.public_card, false); assert.equal("plan" in payload.public_card, false);
});
test("same-email default follows later public email edits and disabled client details remain reusable", () => {
  const form = clientForm(decodeClientContact({ contact: { ...contact, recipient_email: "public@example.invalid" } }, listing));
  form.public_card.email = "changed@example.invalid";
  assert.equal(clientContactPayload(form, 2).recipient_email, "changed@example.invalid");
  form.enabled = false; const payload = clientContactPayload(form, 2);
  assert.equal(payload.enabled, false); assert.equal(payload.public_card.name, "Client Agent"); assert.equal(payload.photo_asset_id, photo);
});
test("mixed-case public email follows the server’s canonical recipient without creating a separate destination", () => {
  const form = clientForm(decodeClientContact({ contact: { ...contact, public_card: {name: "Client", email: "Client@EXAMPLE.invalid"}, recipient_email: "client@example.invalid" } }, listing));
  assert.equal(form.separate_recipient, false);
  assert.equal(clientContactPayload(form, 2).recipient_email, "client@example.invalid");
  assert.equal(clientContactPayload(form, 2).public_card.email, "Client@EXAMPLE.invalid");
});
test("client payload validates delivery address and injected public links without mutating the input", () => {
  const form = clientForm(decodeClientContact({ contact }, listing)), original = structuredClone(form);
  for (const bad of [{ ...form, recipient_email: "client@example.invalid?bcc=leak" }, { ...form, public_card: { ...form.public_card, name: "account@example.invalid" } }, { ...form, public_card: { ...form.public_card, website: "javascript:alert(1)" } }, { ...form, public_card: { ...form.public_card, phone: "123;ext=evil" } }]) assert.throws(() => clientContactPayload(bad, 2));
  assert.deepEqual(form, original); assert.throws(() => clientContactPayload(form, -1));
});
test("contact headshot upload accepts only bounded publishable images", () => {
  assert.deepEqual(validateUpload({ name: "client.jpg", type: "image/jpeg", size: 100 }, "contact_photo"), { kind: "photo", contentType: "image/jpeg" });
  assert.throws(() => validateUpload({ name: "client.mp4", type: "video/mp4", size: 100 }, "contact_photo"), /photo/);
  assert.throws(() => validateUpload({ name: "client.heic", type: "image/heic", size: 100 }, "contact_photo"), /JPG/);
  assert.throws(() => validateUpload({ name: "client.jpg", type: "image/jpeg", size: 11 * 1024 ** 2 }, "contact_photo"), /10 MB/);
});
test("real estate professional preference is optional and separate from permission roles", () => {
  assert.equal(decodeRealEstateRole(undefined), null); assert.equal(decodeRealEstateRole(null), null);
  assert.equal(decodeRealEstateRole("photographer_videographer"), "photographer_videographer"); assert.equal(decodeRealEstateRole("agent"), "agent");
  for (const invalid of ["owner", "admin", true, 1]) assert.throws(() => decodeRealEstateRole(invalid));
});
test("headshots never become property gallery or rendering candidates", () => {
  const key = `renders/${org}/${listing}/contact-${photo}.jpg`;
  const decoded = decodeListingState({ org_id: org, listing_id: listing, assets: [{ id: photo, listing_id: listing, storage_key: key, bucket: "renders", kind: "photo", uploaded: true, created_at: contact.updated_at }], photos: [{ id: photo, listing_id: listing, original_key: key, enhanced_key: null, caption: "Client", is_staged: false, is_main: false, sort: 0 }], jobs: [], renders: [], chapters: [], next_offset: null }, org, listing);
  assert.deepEqual(decoded.assets, []); assert.deepEqual(decoded.photos, []);
});
