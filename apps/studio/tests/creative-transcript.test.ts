import test from "node:test";
import assert from "node:assert/strict";
import {
  importSubtitleTranscript,
  TRANSCRIPT_FILE_BYTES,
} from "../src/features/creative/transcript";
import { parseTranscript } from "../src/features/creative/model";
const srt =
  "1\n00:00:00,000 --> 00:00:02,500\nWelcome inside.\n\n2\n00:00:04,125 --> 00:00:07,000\nThe <i>kitchen</i> &amp; patio.\n\n3\n00:00:09,050 --> 00:00:12,000\nThree bedrooms.";
test("SRT import retains exact cue starts and reviews subtitle markup as ordinary words", () => {
  const value = importSubtitleTranscript(srt, "srt", 30);
  assert.deepEqual(parseTranscript(value, 30), [
    { t: 0, text: "Welcome inside." },
    { t: 4.125, text: "The kitchen & patio." },
    { t: 9.05, text: "Three bedrooms." },
  ]);
});
test("WebVTT import reads real cue times, cue IDs and multiline captions while ignoring subtitle styling", () => {
  const vtt =
    "\uFEFFWEBVTT\r\n\r\nNOTE exported subtitles\r\nNo timing is invented.\r\n\r\nintro\r\n00:00.000 --> 00:02.000 align:start\r\nWelcome\r\ninside.\r\n\r\n00:04.000 --> 00:07.000\r\nKitchen.\r\n\r\n00:09.000 --> 00:12.000\r\nPatio.";
  assert.deepEqual(
    parseTranscript(importSubtitleTranscript(vtt, "vtt", 30), 30),
    [{ t: 0, text: "Welcome inside." }, { t: 4, text: "Kitchen." }, {
      t: 9,
      text: "Patio.",
    }],
  );
});
test("subtitle import refuses missing times, overlapping cues and text outside the selected video", () => {
  for (
    const bad of [
      srt.replace("00:00:04,125", "00:00:01,125"),
      srt.replace("00:00:12,000", "00:00:32,000"),
      srt.replace("00:00:07,000", "00:00:03,000"),
      srt.replace("00:00:04,125", "00:75:04,125"),
      "Words without a timestamp",
    ]
  ) assert.throws(() => importSubtitleTranscript(bad, "srt", 30));
  assert.throws(() => importSubtitleTranscript(srt, "vtt", 30), /WEBVTT/);
});
test("subtitle import is bounded and never creates missing speech phrases", () => {
  assert.throws(
    () =>
      importSubtitleTranscript(
        "x".repeat(TRANSCRIPT_FILE_BYTES + 1),
        "srt",
        30,
      ),
    /256/,
  );
  assert.throws(
    () =>
      importSubtitleTranscript(
        srt.split("\n\n").slice(0, 2).join("\n\n"),
        "srt",
        30,
      ),
    /three timed phrases/,
  );
  assert.throws(
    () =>
      importSubtitleTranscript(
        srt.replace("Welcome inside.", "x".repeat(201)),
        "srt",
        30,
      ),
    /200 characters/,
  );
});
