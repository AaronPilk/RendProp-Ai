import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeChapters,
  decodeCutaways,
  decodeDraft,
  decodeResult,
  decodeShots,
  EMPTY_DRAFT,
  listingFacts,
  parseTranscript,
  subtitleFile,
} from "../src/features/creative/model";
import type { Listing } from "../src/data/contracts";
const listing: Listing = {
  id: "11111111-1111-4111-8111-111111111111",
  orgId: "22222222-2222-4222-8222-222222222222",
  spaceType: "real_estate",
  address: "12 Private Avenue",
  tagline: "Light-filled interiors",
  status: "ready",
  createdAt: "2026-09-14T00:00:00Z",
  mainPhotoKey: null,
  beds: 3,
  baths: 2,
  sqft: 1500,
  priceCents: 35000000,
  details: {
    features: "Patio",
    owner: "private name",
    access_code: "1234",
    address: "12 Private Avenue",
    notes: "Private owner text",
  },
};
test("copy assist uses property facts without exporting street address, owner or access notes", () => {
  const facts = listingFacts(listing), encoded = JSON.stringify(facts);
  assert.equal(facts.beds, 3);
  assert.match(encoded, /Patio/);
  for (
    const privateValue of [
      "12 Private Avenue",
      "private name",
      "1234",
      "Private owner text",
    ]
  ) assert.ok(!encoded.includes(privateValue));
});
test("shot plans only match offered photo IDs and reject duplicate or unusable timing", () => {
  const shots = decodeShots([
    { photo_id: "b", order: 2, seconds: 5 },
    { photo_id: "a", order: 1, seconds: 3 },
    { photo_id: "other", seconds: 5 },
    { photo_id: "a", seconds: 5 },
    { photo_id: "c", seconds: 99 },
  ], ["a", "b", "c"]);
  assert.deepEqual(shots.map((s) => s.photoId), ["a", "b"]);
});
test("timed agent transcripts preserve actual speech order and reject guessed timestamps", () => {
  assert.deepEqual(
    parseTranscript(
      "0:00 Welcome home\n0:04 A spacious kitchen\n0:09 Step onto the patio",
      20,
    ),
    [{ t: 0, text: "Welcome home" }, { t: 4, text: "A spacious kitchen" }, {
      t: 9,
      text: "Step onto the patio",
    }],
  );
  assert.throws(
    () => parseTranscript("0:00 Hello\n0:09 Later\n0:04 Earlier", 20),
    /must increase/,
  );
  assert.throws(
    () => parseTranscript("Hello\nA kitchen\nA patio", 20),
    /Start each transcript/,
  );
  assert.throws(() => parseTranscript("0:00 A\n0:05 B\n0:30 C", 20), /inside/);
});
test("agent cutaways cannot cover the opening/closing face or unrelated photos", () => {
  assert.deepEqual(
    decodeCutaways(
      [
        { photo_id: "a", start: 0, end: 3 },
        { photo_id: "a", start: 2, end: 5 },
        { photo_id: "unknown", start: 7, end: 9 },
        { photo_id: "b", start: 27, end: 29 },
      ],
      ["a", "b"],
      30,
    ),
    [{ photoId: "a", start: 2, end: 5, caption: "", motion: "" }],
  );
});
test("room chapters drop missing or invalid times instead of inventing zero", () => {
  assert.deepEqual(
    decodeChapters([{ label: "Kitchen", start_s: 12.5 }, { label: "Bedroom" }, {
      label: "Entry",
      start_s: 0,
    }, { label: "Invalid", start_s: -4 }]),
    [{ start_s: 0, label: "Entry", room_type: "other", sort: 0 }, {
      start_s: 12.5,
      label: "Kitchen",
      room_type: "other",
      sort: 1,
    }],
  );
});
test("creative documents roundtrip typed content and reject unknown schema", () => {
  const draft = {
    ...EMPTY_DRAFT,
    script: "Property script",
    agentAssetId: "11111111-1111-4111-8111-111111111111",
    agentDuration: 30,
    agentTranscript: "0:00 Welcome.\n0:04 Kitchen.\n0:08 Patio.",
    chapters: [{ start_s: 0, label: "Entry", room_type: "other", sort: 0 }],
    updatedAt: "2026-09-14T00:00:00Z",
  };
  assert.deepEqual(decodeDraft(draft), draft);
  assert.equal(decodeDraft({ schema: 1 }).agentAssetId, null);
  assert.equal(
    decodeDraft({ schema: 1, agentDuration: 200 }).agentDuration,
    null,
  );
  assert.throws(() => decodeDraft({ ...draft, schema: 2 }), /newer version/);
});
test("creative results reject unapproved media hosts and do not decode arbitrary provider metadata", () => {
  const raw = {
    id: "11111111-1111-4111-8111-111111111111",
    kind: "video",
    state: "processing",
    status_url: "https://provider.invalid/private-job",
    metadata: { secret: "private" },
  };
  const result = decodeResult(raw);
  assert.equal(result.url, null);
  assert.ok(!JSON.stringify(result).includes("private-job"));
  assert.throws(
    () => decodeResult({ ...raw, url: "https://unknown.invalid/video.mp4" }),
    /invalid media/,
  );
  assert.throws(
    () =>
      decodeResult({
        ...raw,
        source_url:
          "https://evil012345678901234567890123456789ab.r2.cloudflarestorage.com/file",
      }),
    /invalid media/,
  );
});
test("caption export uses service timing and removes embedded line breaks", () => {
  assert.equal(
    subtitleFile([{ text: "Bright", start: 1.25, end: 1.6 }, {
      text: "kitchen\nspace",
      start: 1.7,
      end: 2.4,
    }]),
    "1\n00:00:01,250 --> 00:00:02,400\nBright kitchen space\n",
  );
});
