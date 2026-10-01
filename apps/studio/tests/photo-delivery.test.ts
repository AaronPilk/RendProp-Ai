import assert from "node:assert/strict";
import test from "node:test";
import { photoFrame, buildPhotoDownload, photoCaption } from "../src/features/creative/photo-export";
import { importedPhoto, inputForEdit, photoDelivery } from "../src/features/creative/photo-lineage";
import type { PhotoDelivery } from "../src/features/creative/photo-lineage";

const original = new File([Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10])], "original.png", { type: "image/png" });
const current = new File(["different edited bytes"], "edited.png", { type: "image/png" });
const source = importedPhoto({ file: original, base64: "original", mime: "image/jpeg", preview: "original-preview" });
const delivery = photoDelivery(source, current, "declutter", "Movable clutter removed with AI.", null);
const renderer = async () => ({ blob: new Blob(["jpeg-render-fixture"]), ...photoFrame(1200, 800, "original") });
async function files(blob: Blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer()), view = new DataView(bytes.buffer), result = new Map<string, Uint8Array>();
  let offset = 0;
  while (view.getUint32(offset, true) === 0x04034b50) {
    const size = view.getUint32(offset + 18, true), nameSize = view.getUint16(offset + 26, true), extra = view.getUint16(offset + 28, true);
    const start = offset + 30 + nameSize + extra;
    result.set(new TextDecoder().decode(bytes.slice(offset + 30, offset + 30 + nameSize)), bytes.slice(start, start + size));
    offset = start + size;
  }
  return result;
}
test("photo framing preserves source pixels by default and crops without stretching or upscaling", () => {
  assert.deepEqual(photoFrame(4000, 3000, "original"), { x: 0, y: 0, cropWidth: 4000, cropHeight: 3000, width: 4000, height: 3000 });
  const frame = photoFrame(1200, 800, "9:16");
  assert.equal(frame.cropHeight, 800); assert.equal(frame.cropWidth, 450); assert.equal(frame.x, 375);
  for (const ratio of ["original", "4:3", "16:9", "3:2", "1:1", "4:5", "9:16"] as const) {
    const value = photoFrame(301, 199, ratio);
    assert.ok(value.width <= value.cropWidth && value.height <= value.cropHeight);
    assert.ok(Math.abs(value.width / value.height - value.cropWidth / value.cropHeight) < .02);
  }
  assert.throws(() => photoFrame(100_000, 100_000, "original"), /large/);
  assert.throws(() => photoFrame(1, 1, "9:16"), /small/, "a subpixel crop must not upscale to one pixel");
});
test("edit input and immutable original remain distinct, with a real pre-stage input for restyles", () => {
  const staged = { ...source, file: current, base64: "staged", stageBase: { ...source, base64: "decluttered", disclosures: ["Clutter removed."], edits: ["Digitally decluttered"] } };
  assert.equal(inputForEdit(staged, "stage").base64, "decluttered");
  assert.equal(inputForEdit(staged, "sky").base64, "staged");
  const result = photoDelivery({ ...staged, disclosures: ["Clutter removed."], edits: ["Digitally decluttered"] }, current, "stage", "Furniture digitally added.", null);
  assert.equal(result.original, original);
  assert.deepEqual(result.disclosures, ["Clutter removed.", "Furniture digitally added."]);
  assert.deepEqual(result.edits, ["Digitally decluttered", "Virtually staged"]);
  const later = { ...staged, disclosures: ["Clutter removed.", "Furniture added.", "Twilight generated."], edits: ["Digitally decluttered", "Virtually staged", "Digital twilight"] };
  const restyled = photoDelivery(later, current, "stage", "Furniture digitally added.", null);
  assert.deepEqual(restyled.disclosures, ["Clutter removed.", "Furniture digitally added."], "new disclosure must follow the actual pre-stage input");
  assert.deepEqual(restyled.edits, ["Digitally decluttered", "Virtually staged"], "do not claim twilight when those pixels are not in the input");
  const repeated = photoDelivery({ ...staged, disclosures: ["Clutter removed.", "Furniture digitally added."] }, current, "declutter", "Clutter removed.", null);
  assert.deepEqual(repeated.disclosures, ["Furniture digitally added.", "Clutter removed."], "saving can append the current server disclosure without losing earlier staging");
});
test("photo package retains exact original bytes, separate caption, hashes and clean MLS metadata", async () => {
  const result = await buildPhotoDownload([delivery], { destination: "mls", ratio: "original" }, new AbortController().signal, () => {}, renderer);
  const zip = await files(result.blob), originalEntry = [...zip].find(([name]) => name.includes("01-original"))!;
  assert.deepEqual(originalEntry[1], new Uint8Array(await original.arrayBuffer()));
  const proof = JSON.parse(new TextDecoder().decode(zip.get("provenance.json")));
  assert.equal(proof.publicOriginalURL, null); assert.equal(proof.files[0].visibleLabel, null);
  assert.match(proof.files[0].original.sha256, /^[a-f0-9]{64}$/);
  assert.match(new TextDecoder().decode(zip.get("captions.txt")), /Movable clutter removed with AI/);
  assert.ok([...zip.keys()].some(path => path.endsWith("02-edited.jpg")));
});
test("legacy unknown history still downloads the edited JPEG without claiming or bundling an original", async () => {
  const unverified: PhotoDelivery = { ...delivery, original: null, originalPreview: null, originalVerified: false };
  const result = await buildPhotoDownload([unverified], { destination: "mls", ratio: "original" }, new AbortController().signal, () => {}, renderer);
  const zip = await files(result.blob);
  assert.ok([...zip.keys()].some(path => path.endsWith("edited.jpg")));
  assert.ok(![...zip.keys()].some(path => path.includes("original.png")));
  assert.match(photoCaption(unverified), /unverified/);
  assert.equal(JSON.parse(new TextDecoder().decode(zip.get("provenance.json"))).files[0].original, null);
});
test("account change during rendering refuses the whole download", async () => {
  let currentAccount = true;
  await assert.rejects(buildPhotoDownload([delivery], { destination: "mls", ratio: "original" }, new AbortController().signal,
    () => { if (!currentAccount) throw new Error("Account changed"); }, async () => { currentAccount = false; return renderer(); }), /Account changed/);
});
test("aborted download and signed-link disclosure cannot escape into a package", async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(buildPhotoDownload([delivery], { destination: "mls", ratio: "original" }, controller.signal, () => {}, renderer), /abort/i);
  assert.ok(!photoCaption({ ...delivery, disclosures: ["AI edit https://uploads.rendprop.com/private?signature=secret"] }).includes("secret"));
});
