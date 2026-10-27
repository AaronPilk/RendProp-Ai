import assert from "node:assert/strict";
import test from "node:test";
import { createTourQR } from "../src/features/listings/qr";
import { resolveTourLinks, safeTourLinks, verifiedTourShareURL } from "../src/features/listings/share-link";

const slug = "fixture-live-property";
const endpoint = `https://rendprop.com/f/${slug}/share-link`;
const dated = `https://rendprop.com/property/855-central-ave-1120-saint-petersburg-fl-united-states/20261027.${slug}`;
const undated = `https://rendprop.com/property/855-central-ave-1120-saint-petersburg-fl-united-states/${slug}`;
const bare = "https://rendprop.com/property/855-central-ave-1120-saint-petersburg-fl-united-states";
const fallback = { branded: `https://rendprop.com/f/${slug}`, unbranded: `https://rendprop.com/u/${slug}` };
function response(body: unknown, status = 200, url = endpoint) {
  const result = new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  Object.defineProperty(result, "url", { value: url });
  return result;
}

test("only the expected address paths are accepted for the same publication", () => {
  assert.equal(verifiedTourShareURL(dated, false, slug), dated);
  assert.equal(verifiedTourShareURL(undated, false, slug), undated);
  assert.equal(verifiedTourShareURL(bare, true, slug), bare);
  assert.equal(verifiedTourShareURL(bare, false, slug), null);
  assert.equal(verifiedTourShareURL(dated, true, slug), null);
  for (const candidate of [
    `https://rendprop.com/f/${slug}`, `https://rendprop.com/u/${slug}`,
    dated.replace(slug, "other-publication"),
    dated.replace("20261027.", "20261027-"),
    dated.replace("/property/", "/property/-bad-/"),
    dated.replace("https://rendprop.com", "http://rendprop.com"),
    dated.replace("https://rendprop.com", "https://fake.rendprop.com"),
    dated.replace("https://rendprop.com", "https://rendprop.com.evil.invalid"),
    dated.replace("https://rendprop.com", "https://rendprop.com:444"),
    dated.replace("https://rendprop.com", "https://user@rendprop.com"),
    `${dated}?next=https://evil.invalid`, `${dated}#fragment`,
    dated.replace("/property/", "/property/%38"),
  ]) assert.equal(verifiedTourShareURL(candidate, false, slug), null, candidate);
  assert.equal(verifiedTourShareURL(undated.replace(slug, "other-publication"), false, slug), null);
  assert.equal(verifiedTourShareURL(bare + "-", true, slug), null);
  assert.equal(verifiedTourShareURL(dated, "false", slug), null);
  assert.equal(verifiedTourShareURL(dated, false, "bad/slug"), null);
});

test("the public read is credential-free and carries the authoritative address into the QR", async () => {
  let calls = 0;
  const resolved = await resolveTourLinks(slug, { fetcher: async (input, init) => {
    calls++;
    assert.equal(input, endpoint);
    assert.equal(init?.method, "GET"); assert.equal(init?.cache, "no-store");
    assert.equal(init?.credentials, "omit"); assert.equal(init?.referrerPolicy, "no-referrer");
    assert.equal(init?.redirect, "error");
    assert.equal((init?.headers as Record<string, string>).Accept, "application/json");
    return response({ url: dated, address_only: false, canonical_url: dated, is_indexable: true });
  } });
  assert.equal(calls, 1);
  assert.deepEqual(resolved, { links: { branded: dated, unbranded: fallback.unbranded }, verified: true, addressOnly: false });
  assert.deepEqual(safeTourLinks(slug, resolved), resolved?.links);
  const qr = await createTourQR(slug, "branded", resolved ?? undefined);
  const { default: qrcode } = await import("qrcode-generator");
  const expected = qrcode(0, "M"); expected.addData(dated); expected.make();
  assert.equal(qr, expected.createSvgTag({ cellSize: 12, margin: 48, scalable: true }));
  const mls = qrcode(0, "M"); mls.addData(fallback.unbranded); mls.make();
  assert.equal(await createTourQR(slug, "unbranded", resolved ?? undefined), mls.createSvgTag({ cellSize: 12, margin: 48, scalable: true }));
});

test("bare legacy and undated noindex responses remain usable but unproven links fall back", async () => {
  for (const [url, addressOnly] of [[bare, true], [undated, false]] as const) {
    const result = await resolveTourLinks(slug, { fetcher: async () => response({ url, address_only: addressOnly }) });
    assert.equal(result?.verified, true); assert.equal(result?.addressOnly, addressOnly); assert.equal(result?.links.branded, url);
  }
  for (const returned of [
    response({ url: dated, address_only: false }, 503),
    response({ url: dated, address_only: false }, 200, "https://evil.invalid/redirect"),
    response({ url: `https://rendprop.com/f/${slug}`, address_only: false }),
    response({ url: dated.replace(slug, "other-publication"), address_only: false }),
    response("not json"),
    response({ url: dated, address_only: false, filler: "x".repeat(2100) }),
  ]) {
    const result = await resolveTourLinks(slug, { fetcher: async () => returned });
    assert.deepEqual(result, { links: fallback, verified: false, addressOnly: null });
  }
  assert.deepEqual(safeTourLinks(slug, { links: { branded: `https://evil.invalid/property/a/${slug}`, unbranded: fallback.unbranded }, verified: true, addressOnly: false }), fallback);
  assert.deepEqual(safeTourLinks(slug, { links: { branded: dated, unbranded: "https://evil.invalid" }, verified: true, addressOnly: false }), fallback);
  assert.deepEqual(safeTourLinks(slug, { links: { branded: bare, unbranded: fallback.unbranded }, verified: true, addressOnly: false }), fallback);
  assert.deepEqual(safeTourLinks(slug, { links: { branded: bare, unbranded: fallback.unbranded }, verified: true, addressOnly: true }), { branded: bare, unbranded: fallback.unbranded });
});

test("a caller-aborted lookup cannot publish a late response", async () => {
  const controller = new AbortController();
  let release!: (value: Response) => void;
  const pending = resolveTourLinks(slug, { signal: controller.signal, fetcher: async () => new Promise<Response>(resolve => { release = resolve; }) });
  controller.abort(); release(response({ url: dated, address_only: false }));
  await assert.rejects(pending);
});
