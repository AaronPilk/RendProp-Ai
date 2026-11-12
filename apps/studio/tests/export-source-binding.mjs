import {createHash} from "node:crypto";
import {readFile} from "node:fs/promises";
import {join} from "node:path";

// Both the main producer and the emitted worker are part of the exporter.
// This exact inventory is shared by browser receipts and CI binding checks.
export const EXPORT_SOURCE_PATHS = Object.freeze([
  "package.json", "package-lock.json", "node_modules/mediabunny/package.json",
  ...["export", "export-continuity", "export-webcodecs", "export-frame-seek", "export-audio", "export-audio-prime", "export-audio-route", "export-audio-schedule", "export-pcm", "export-pcm-ownership",
    "export-audio-bootstrap", "export-plan", "encoder-protocol",
    "encoder-worker", "encoder-bridge", "encoder-output", "recording-clock",
    "model", "media", "music", "finishing", "overlays", "overlay-renderer", "mp4-cadence", "proxy"]
    .map(name => `src/editor/${name}.ts`),
  "src/editor/export-pcm-worklet.js",
  "src/editor/VideoEditor.tsx",
  "tests/export-source-binding.mjs",
]);

export async function exportSourceHashes(root, additional = []) {
  const paths = [...new Set([...EXPORT_SOURCE_PATHS, ...additional])].sort();
  return Object.fromEntries(await Promise.all(paths.map(async path => [path,
    createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
}
