/* Integrated shipping-entry decoded-media oracles; no exporter mutation.
 * The combined oracle body is byte-identical to frozen combined-v3.
 */
import assert from "node:assert/strict";
import {execFileSync} from "node:child_process";
import {fixedAACTailWindow, fixedPCMWindow, measureTonePCM,
  requireAudibleFadeOut} from "./finishing-audio-probe.mjs";

const RATE = 48_000;
const FPS = 30;
const DURATION = 5.5;
const FRAMES = 165;
const TWO_FRAMES = 2 / FPS;
const command = (binary, args, options = {}) => execFileSync(binary, args,
  {timeout: 30_000, maxBuffer: 64 * 1024 * 1024, ...options});
const probe = (file, args) => JSON.parse(command("ffprobe",
  ["-v", "error", ...args, "-of", "json", file], {encoding: "utf8"}));
const rgb = (file, time, x = 100) => [...command("ffmpeg",
  ["-v", "error", "-ss", String(time), "-i", file, "-frames:v", "1",
    "-vf", `format=rgb24,crop=1:1:${x}:400`, "-f", "rawvideo", "pipe:1"])];
const pcm = file => {
  const bytes = command("ffmpeg", ["-v", "error", "-i", file,
    "-vn", "-ac", "1", "-ar", String(RATE), "-f", "f32le", "pipe:1"]);
  assert.equal(bytes.byteLength % 4, 0);
  return {bytes, samples: new Float32Array(bytes.buffer, bytes.byteOffset,
    bytes.byteLength / 4)};
};
const component = (samples, hz, start, end) => {
  const first = Math.round(start * RATE), last = Math.round(end * RATE);
  assert(first >= 0 && last <= samples.length && last > first);
  let sine = 0, cosine = 0;
  for (let index = first; index < last; index++) {
    const phase = 2 * Math.PI * hz * (index - first) / RATE;
    sine += samples[index] * Math.sin(phase);
    cosine += samples[index] * Math.cos(phase);
  }
  return 2 * Math.hypot(sine, cosine) / (last - first);
};
const power = (samples, start, end) => {
  const first = Math.round(start * RATE), last = Math.round(end * RATE);
  assert(first >= 0 && last <= samples.length && last > first);
  let sum = 0;
  for (let index = first; index < last; index++) sum += samples[index] ** 2;
  return Math.sqrt(sum / (last - first));
};
const peakNear = (samples, hz, start, end) => {
  let best = {hz: 0, level: 0};
  for (let candidate = hz - 30; candidate <= hz + 30; candidate += 2) {
    const level = component(samples, candidate, start, end);
    if (level > best.level) best = {hz: candidate, level};
  }
  return best;
};
const assertComponent = (samples, hz, start, end, minimum, message) => {
  const row = peakNear(samples, hz, start, end);
  assert(row.level > minimum && Math.abs(row.hz - hz) <= 30,
    `${message}: ${JSON.stringify(row)}`);
  return row;
};

function verifyAudio(samples) {
  assert(samples.length >= Math.round((DURATION - TWO_FRAMES) * RATE) &&
    samples.length <= Math.round((DURATION + TWO_FRAMES) * RATE),
  "Decoded AAC length moved outside the two-frame bound");
  assert(power(samples, .02, .08) < .01,
    "Pre-narration/pre-music photo gained a content prefix");
  const firstMarker = [];
  for (let step = 0; step <= 33; step++) {
    const at = .5 + step * .002;
    firstMarker.push({at, end: at + .01,
      opening: component(samples, 990, at, at + .01),
      body: component(samples, 880, at, at + .01)});
  }
  assert(firstMarker.some(row => row.opening > .03 &&
    row.opening > row.body * 1.5 && row.end <= .5 + TWO_FRAMES),
  "First 990 Hz opening marker missed its two-frame onset or was masked");
  const firstBody = [.75, 1.20, 1.80, 2.30].map(at => ({at,
    peak: assertComponent(samples, 880, at, at + .08, .0425,
      "2× original body is missing"),
    doubled: component(samples, 1760, at, at + .08)}));
  assert(firstBody.every(row => row.peak.level > row.doubled * 2),
    "The 2× original source changed pitch to 1760 Hz");
  for (let at = .72; at + .04 <= 2.38; at += .04)
    assert(component(samples, 880, at, at + .04) > .0425,
      `2× original source lost a 40 ms body window at ${at}`);

  const secondMarker = [];
  for (let step = 0; step <= 33; step++) {
    const at = 3 + step * .002;
    secondMarker.push({at, end: at + .01,
      opening: component(samples, 770, at, at + .01),
      body: component(samples, 1100, at, at + .01)});
  }
  assert(secondMarker.some(row => row.opening > .03 &&
    row.opening > row.body * 1.5 && row.end <= 3 + TWO_FRAMES),
  "Trimmed normal-source 770 Hz marker missed its exact boundary");
  const secondBody = [3.30, 3.70, 4.05, 4.30, 4.65].map(at => ({at,
    peak: assertComponent(samples, 1100, at, at + .08, .0425,
      "Trimmed normal original body is missing")}));
  for (let at = 3.25; at + .04 <= 4.85; at += .04)
    assert(component(samples, 1100, at, at + .04) > .0425,
      `Normal original source lost a 40 ms body window at ${at}`);

  const voiceRef = component(samples, 660, .90, 1.10);
  const voiceEarly = component(samples, 660, .22, .32);
  const voiceTail = component(samples, 660, 4.00, 4.10);
  const voiceAfter = component(samples, 660, 4.28, 4.38);
  assert(voiceRef > .15 && voiceEarly > voiceRef * .7 &&
    voiceTail > voiceRef * .7 && voiceAfter < voiceRef * .08,
  "Narration offset, tail or ending shifted");
  const boundaryVoice = [.44, .54, 2.44, 2.54, 2.94, 3.04].map(at =>
    component(samples, 660, at, at + .04));
  assert(boundaryVoice.every(level => level > voiceRef * .5),
    "Narration developed a clip-boundary seam");
  // The source itself switches to 1320 Hz only at 1.25–1.50 seconds. Its
  // saved .15-second offset puts that interval at output 1.40–1.65. This
  // catches an incorrect source offset after the photo→video rearm, which a
  // constant 660 Hz narration could not distinguish from repeated content.
  const voiceMarker = {
    before660: component(samples, 660, 1.30, 1.38),
    before1320: component(samples, 1320, 1.30, 1.38),
    marker660: component(samples, 660, 1.48, 1.56),
    marker1320: component(samples, 1320, 1.48, 1.56),
    after660: component(samples, 660, 1.70, 1.78),
    after1320: component(samples, 1320, 1.70, 1.78),
  };
  assert(voiceMarker.before660 > .15 && voiceMarker.after660 > .15 &&
    voiceMarker.before1320 < voiceMarker.before660 * .08 &&
    voiceMarker.after1320 < voiceMarker.after660 * .08 &&
    voiceMarker.marker1320 > .15 &&
    voiceMarker.marker660 < voiceMarker.marker1320 * .1,
  "Narration source marker shifted, repeated, or leaked outside its saved offset");

  const originalDuck = component(samples, 1100, 3.70, 3.82);
  const originalRestored = component(samples, 1100, 4.30, 4.42);
  assert(originalRestored > .04 &&
    originalDuck / originalRestored > .12 &&
    originalDuck / originalRestored < .4,
  "Original audio did not duck during narration and recover afterward");
  const musicReference = component(samples, 220, 5.04, 5.19);
  const musicVoicePhoto = component(samples, 220, 2.70, 2.80);
  const musicOriginalOnly = component(samples, 220, 4.35, 4.45);
  const musicFadeEarly = component(samples, 220, .22, .30);
  const musicFadeLater = component(samples, 220, .32, .40);
  assert(musicReference > .07 &&
    musicVoicePhoto / musicReference > .10 &&
    musicVoicePhoto / musicReference < .4 &&
    musicOriginalOnly / musicReference > .10 &&
    musicOriginalOnly / musicReference < .4,
  "Music duck/recovery changed across source and photo windows");
  // The original fade oracle's independent linear-ramp-plus-25ms-smoothing
  // lower bound, adapted to the saved .3s fade and fixed .22–.30s probe.
  const tau = .025, lag = 1 / 30 + .005;
  const integral = u => u * u / 2 - tau * u -
    tau * tau * Math.exp(-u / tau);
  const lowerMean = (integral(.20 - lag) - integral(.12 - lag)) /
    (.08 * .3);
  assert(musicFadeEarly >= musicVoicePhoto * lowerMean * .8 &&
    musicFadeLater > musicFadeEarly * 1.5 &&
    musicFadeLater < musicVoicePhoto * .9,
  "Music fade-in or early offset shifted");
  const cutawayBefore = component(samples, 1100, 3.35, 3.43);
  const cutawayDuring = component(samples, 1100, 3.70, 3.78);
  const cutawayAfter = component(samples, 1100, 4.05, 4.13);
  assert(cutawayDuring > cutawayBefore * .6 &&
    cutawayDuring < cutawayBefore * 1.5 &&
    cutawayAfter > cutawayBefore * .6 &&
    cutawayAfter < cutawayBefore * 1.5,
  "Image cutaway interrupted base original sound");
  return {firstMarker, firstBody, secondMarker, secondBody,
    voice: {voiceRef, voiceEarly, voiceTail, voiceAfter, boundaryVoice,
      voiceMarker},
    originalDuck, originalRestored,
    music: {musicReference, musicVoicePhoto, musicOriginalOnly,
      musicFadeEarly, musicFadeLater,
      fadeOracle: {tau, lag, lowerMean, codecAmplitudeAllowance: .2}},
    cutawayAudio: {cutawayBefore, cutawayDuring, cutawayAfter}};
}

function verifyPixels(file) {
  // These are the original strict v5 purple→blue dissolve and blue→red whip
  // pixels and fixed sample windows, not a relaxed transition surrogate.
  const before = rgb(file, .4), after = rgb(file, 1.1);
  const dissolve = [.54, .58, .62, .66, .70, .74, .78, .82, .86]
    .map(time => ({time, rgb: rgb(file, time)}));
  const blends = dissolve.filter(({rgb: value}) => value[0] > 20 &&
    value[0] < 100 && value[2] > 170 && value[2] < 245);
  assert(blends.some((sample, index) => blends.slice(index + 1).some(later =>
    sample.rgb[0] - later.rgb[0] >= 8 &&
    later.rgb[2] - sample.rgb[2] >= 8)),
  "Dissolve did not progress through decoded colors");
  assert(before[0] > 100 && before[0] < 135 &&
    before[1] > 65 && before[1] < 95 &&
    before[2] > 135 && before[2] < 175,
  "Preceding shot must be purple");
  assert(after[0] < 10 && after[1] < 10 && after[2] > 240,
    "Following shot must be blue");
  const isWhip = ({left, right}) => left[2] > 200 && left[0] < 30 &&
    right[0] > 200 && right[2] < 30;
  const beforeWhip = {left: rgb(file, 2.4, 100),
    right: rgb(file, 2.4, 650)};
  const whip = [2.54, 2.58, 2.62, 2.66, 2.70, 2.74]
    .map(time => ({time, left: rgb(file, time, 100),
      right: rgb(file, time, 650)}));
  const afterWhip = {left: rgb(file, 2.9, 100),
    right: rgb(file, 2.9, 650)};
  assert(whip.some(isWhip),
    "Whip must split outgoing blue and incoming red");
  assert(beforeWhip.left[2] > 200 && beforeWhip.right[2] > 200 &&
    !isWhip(beforeWhip), "Preceding shot must remain blue before whip");
  assert(afterWhip.left[0] > 200 && afterWhip.right[0] > 200 &&
    !isWhip(afterWhip), "Following shot must be fully red after whip");
  const green = rgb(file, 3.7);
  const beforeCutaway = rgb(file, 3.3);
  const afterCutaway = rgb(file, 4.2);
  const isGreen = value => value[0] < 30 && value[1] > 200 && value[2] < 30;
  assert(isGreen(green) && !isGreen(beforeCutaway) && !isGreen(afterCutaway),
    "Image cutaway did not appear and return to the moving base");
  // Source two is red with a 40-pixel white stripe at x = 220*t - 90.
  // The output trims to source .5, so output 3.15 -> source .65 and
  // output 4.15 -> source 1.65. These fixed probes test real seek/motion.
  // Render dimensions are 1280×720, so map source x through the 1.6× scale.
  const stripeEarly = rgb(file, 3.15, 120);
  const stripeLateOldX = rgb(file, 4.15, 120);
  const stripeLateNewX = rgb(file, 4.15, 470);
  const isWhite = value => value.every(channel => channel > 205);
  const isRed = value => value[0] > 205 && value[1] < 35 && value[2] < 35;
  assert(isWhite(stripeEarly) && isRed(stripeLateOldX) &&
    isWhite(stripeLateNewX),
  "Trimmed normal source did not advance its moving stripe");
  return {before, dissolve, after, beforeWhip, whip, afterWhip,
    cutaway: {beforeCutaway, green, afterCutaway},
    movingSource: {stripeEarly, stripeLateOldX, stripeLateNewX}};
}

export function verifyCombinedOutput(outputFile) {
  const metadata = probe(outputFile, ["-show_streams", "-show_format"]);
  const videos = metadata.streams.filter(row => row.codec_type === "video");
  const audios = metadata.streams.filter(row => row.codec_type === "audio");
  assert.equal(videos.length, 1);
  assert.equal(audios.length, 1);
  assert.equal(videos[0].codec_name, "h264");
  assert.equal(audios[0].codec_name, "aac");
  assert.equal(Number(audios[0].sample_rate), RATE);
  assert.equal(Number(audios[0].channels), 2);
  assert(Math.abs(Number(metadata.format.duration) - DURATION) <= TWO_FRAMES,
    "Combined container duration moved outside two frames");
  assert(Math.abs(Number(videos[0].duration) - Number(audios[0].duration)) <= TWO_FRAMES,
    "Combined audio/video stream durations diverged");
  const frames = probe(outputFile, ["-select_streams", "v:0", "-show_frames",
    "-show_entries", "frame=best_effort_timestamp_time"])
    .frames.map(row => Number(row.best_effort_timestamp_time));
  assert.equal(frames.length, FRAMES);
  frames.sort((a, b) => a - b);
  for (let index = 0; index < frames.length; index++)
    assert(Number.isFinite(frames[index]) &&
      Math.abs(frames[index] - index / FPS) <= .001,
    `Combined decoded frame ${index} PTS changed`);
  const decodedAudio = pcm(outputFile);
  const audio = verifyAudio(decodedAudio.samples);
  const tailWindow = fixedAACTailWindow(metadata, DURATION);
  const fixedTail = fixedPCMWindow(decodedAudio.bytes, tailWindow.probeStart);
  const tail = measureTonePCM(fixedTail, 220);
  requireAudibleFadeOut(tail.amplitude, audio.music.musicReference);
  audio.music.fixedAACTail = {...tailWindow, ...tail};
  return {metadata, decodedPTS: frames,
    audio, pixels: verifyPixels(outputFile)};
}

export function verifyPlannedOutput(file, {seconds, width, height, withAudio}) {
  const metadata = probe(file, ["-show_streams", "-show_format"]);
  const videos = metadata.streams.filter(row => row.codec_type === "video");
  const audios = metadata.streams.filter(row => row.codec_type === "audio");
  assert.equal(videos.length, 1); assert.equal(videos[0].codec_name, "h264");
  assert.equal(Number(videos[0].width), width); assert.equal(Number(videos[0].height), height);
  assert.equal(audios.length, withAudio ? 1 : 0,
    "Optional audio track does not match the actual selected edit");
  if (withAudio) {
    assert.equal(audios[0].codec_name, "aac"); assert.equal(Number(audios[0].channels), 2);
    assert.equal(Number(audios[0].sample_rate), RATE);
    assert(Math.abs(Number(videos[0].duration) - Number(audios[0].duration)) <= TWO_FRAMES);
  }
  const canonical = Math.round(seconds * 1e6) / 1e6;
  const expectedFrames = Math.ceil(canonical * FPS);
  assert(Math.abs(Number(videos[0].duration) - canonical) <= .001,
    "The last video frame must preserve fractional end time, not pad a full frame");
  assert(Math.abs(Number(metadata.format.duration) - seconds) <= TWO_FRAMES);
  const decodedPTS = probe(file, ["-select_streams", "v:0", "-show_frames",
    "-show_entries", "frame=best_effort_timestamp_time"])
    .frames.map(row => Number(row.best_effort_timestamp_time)).sort((a, b) => a - b);
  assert.equal(decodedPTS.length, expectedFrames);
  decodedPTS.forEach((at, index) => assert(Number.isFinite(at) && Math.abs(at - index / FPS) <= .001,
    "Decoded frame PTS skipped or duplicated index " + index));
  return {metadata, decodedPTS, canonicalDuration: canonical};
}

const pixelAt = (file, time, x, y) => [...command("ffmpeg",
  ["-v", "error", "-ss", String(time), "-i", file, "-frames:v", "1",
    "-vf", "format=rgb24,crop=1:1:" + x + ":" + y, "-f", "rawvideo", "pipe:1"])];
function motionCentroid(file, time) {
  const row = command("ffmpeg", ["-v", "error", "-ss", String(time), "-i", file,
    "-frames:v", "1", "-vf", "format=rgb24,crop=720:1:0:400", "-f", "rawvideo", "pipe:1"]);
  let total = 0, sum = 0;
  for (let x = 0; x < 720; x++) if ([0, 1, 2].every(channel => row[x * 3 + channel] > 205)) {
    total++; sum += x;
  }
  assert(total > 25, "Moving photo source marker is not visible");
  return {pixels: total, x: sum / total};
}
function captionPixels(file, time) {
  const bytes = command("ffmpeg", ["-v", "error", "-ss", String(time), "-i", file,
    "-frames:v", "1", "-vf", "format=rgb24,crop=720:350:0:900", "-f", "rawvideo", "pipe:1"]);
  let yellow = 0, glyph = 0;
  for (let at = 0; at < bytes.length; at += 3) {
    if (bytes[at] > 180 && bytes[at + 1] > 180 && bytes[at + 2] < 150) yellow++;
    if (bytes[at] < 80 && bytes[at + 1] < 80 && bytes[at + 2] < 80) glyph++;
  }
  assert(yellow > 1500 && glyph > 40, "Timed caption background and text pixels must both survive");
  return {yellow, glyph};
}

export function verifyAuxiliaryOutput(file, scenario) {
  if (scenario === "fractional") {
    const seconds = .517 + (1.789 - .431) / 1.3 + .683;
    const result = verifyPlannedOutput(file, {seconds, width: 720, height: 1280, withAudio: true});
    const samples = pcm(file).samples, opening = motionCentroid(file, .08), later = motionCentroid(file, .42);
    assert(later.x - opening.x > 250, "The saved photo pan must move actual source pixels");
    assert(power(samples, .08, .40) < .01, "Opening photo must remain silent");
    const source = assertComponent(samples, 1100, .92, 1.12, .04, "Fractional-speed original is missing");
    assert(source.level > component(samples, 1430, .92, 1.12) * 2,
      "Fractional speed must preserve original pitch");
    const before = pixelAt(file, .75, 100, 400), cutaway = pixelAt(file, .98, 100, 400),
      after = pixelAt(file, 1.4, 100, 400);
    assert(before[0] > 205 && before[1] < 35 && before[2] < 35);
    assert(cutaway[0] < 30 && cutaway[1] > 200 && cutaway[2] < 30);
    assert(after[0] > 205 && after[1] < 35 && after[2] < 35);
    return {...result, motion: {opening, later}, captions: captionPixels(file, .85),
      cutaway: {before, cutaway, after}, original: source};
  }
  if (scenario === "muted-music") {
    const result = verifyPlannedOutput(file, {seconds: 1.017, width: 960, height: 960, withAudio: true});
    const samples = pcm(file).samples;
    const music = component(samples, 220, .55, .85), original = component(samples, 880, .55, .85);
    assert(music > .07, "Explicitly selected music must survive muted original audio");
    assert(original < .003, "Muted original audio leaked into the selected music mix");
    return {...result, music, original};
  }
  if (scenario === "silent") return verifyPlannedOutput(file,
    {seconds: 1.2, width: 960, height: 960, withAudio: false});
  assert.equal(scenario, "long");
  const result = verifyPlannedOutput(file, {seconds: 180, width: 1280, height: 720, withAudio: false});
  const shots = Array.from({length: 12}, (_, index) => ({index,
    pixel: pixelAt(file, index * 15 + 7, 100, 400)}));
  shots.forEach(({index, pixel}) => index % 2 ?
    assert(pixel[0] > 205 && pixel[1] < 35 && pixel[2] < 35) :
    assert(pixel[0] > 100 && pixel[0] < 135 && pixel[1] > 65 &&
      pixel[1] < 95 && pixel[2] > 135 && pixel[2] < 175));
  return {...result, shots};
}

function stripeCentroids(file, width, row, frames) {
  // Decode each displayed frame exactly once. Do not add an fps filter or
  // output -r: those could conceal a repeated or skipped source frame.
  const bytes = command("ffmpeg", ["-v", "error", "-i", file, "-an",
    "-vf", `format=rgb24,crop=${width}:1:0:${row}`,
    "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1"]);
  assert.equal(bytes.length, frames * width * 3, "Moving-stripe decoded frame count changed");
  return Array.from({length: frames}, (_, frame) => {
    let count = 0, total = 0;
    for (let x = 0; x < width; x++) {
      const at = (frame * width + x) * 3;
      if (bytes[at] > 205 && bytes[at + 1] > 205 && bytes[at + 2] > 205) {count++; total += x;}
    }
    assert(count > 10 && count < 100, "Every decoded frame needs one finite white stripe");
    return total / count;
  });
}

export function assertSeekCentroidMapping(source, output) {
  assert.equal(source.length, 120); assert.equal(output.length, 60);
  assert(source.every(Number.isFinite) && output.every(Number.isFinite));
  const sourceSteps = source.slice(1).map((value, index) => value - source[index]);
  assert(sourceSteps.every(value => value >= 5 && value <= 7),
    "Actual120fps source must advance six pixels on every frame");
  // .2521 seconds lies 2.1ms inside source frame30. At .25x, successive
  // 30fps output frames therefore consume source frames30+k, not pairs.
  const expected = output.map((_, index) => 1.6 * (source[30 + index] + .5) - .5);
  const errors = output.map((value, index) => Math.abs(value - expected[index]));
  assert(errors.every(value => value <= 2), "Exact seek consumed the wrong120fps source frame");
  const outputSteps = output.slice(1).map((value, index) => value - output[index]);
  // Expected9.6px steps allow the two adjacent pointwise errors (2px each).
  assert(outputSteps.every(value => value >= 5 && value <= 14),
    "Slow-motion export repeated or skipped a moving source frame");
  return {expected, maximumError: Math.max(...errors), sourceSteps, outputSteps};
}

export function inspectSeekSource(file) {
  const metadata = probe(file, ["-show_streams", "-show_format"]);
  const video = metadata.streams.find(value => value.codec_type === "video");
  assert.equal(metadata.streams.length, 1); assert.equal(video?.codec_name, "h264");
  assert.equal(video.width, 800); assert.equal(video.height, 450);
  assert.equal(video.r_frame_rate, "120/1"); assert.equal(video.avg_frame_rate, "120/1");
  assert(Math.abs(Number(video.duration) - 1) <= .001);
  const pts = probe(file, ["-select_streams", "v:0", "-show_frames",
    "-show_entries", "frame=best_effort_timestamp_time"]).frames
    .map(value => Number(value.best_effort_timestamp_time));
  assert.equal(pts.length, 120); assert.equal(new Set(pts).size, 120);
  pts.forEach((value, index) => assert(Number.isFinite(value) && Math.abs(value - index / 120) <= .000001));
  const centroids = stripeCentroids(file, 800, 225, 120);
  // Also validate the reference independently before launching the browser.
  assertSeekCentroidMapping(centroids, centroids.slice(30, 90).map(value => 1.6 * (value + .5) - .5));
  return {metadata, decodedPTS: pts, centroids};
}

export function verifySeekOutput(file, source) {
  const result = verifyPlannedOutput(file, {seconds: 2, width: 1280, height: 720, withAudio: false});
  const centroids = stripeCentroids(file, 1280, 360, 60);
  return {...result, sourceFrameIndices: Array.from({length: 60}, (_, index) => 30 + index),
    centroids, mapping: assertSeekCentroidMapping(source.centroids, centroids)};
}

export function verifyHybridReuseOutput(file) {
  const result = verifyPlannedOutput(file, {seconds: 1.5, width: 1280, height: 720, withAudio: true});
  const samples = pcm(file).samples;
  const markers = [0, 1].map(start => {
    const windows = Array.from({length: 34}, (_, step) => {
      const at = start + step * .002;
      return {at, end: at + .01, opening: component(samples, 990, at, at + .01),
        body: component(samples, 880, at, at + .01)};
    });
    assert(windows.some(value => value.opening > .03 && value.opening > value.body * 1.5 &&
      value.end <= start + TWO_FRAMES), "Reused live source lost its opening marker");
    return {start, windows};
  });
  const body = [0, 1].flatMap(start => Array.from({length: 6}, (_, index) => {
    const at = start + .2 + index * .04;
    const peak = assertComponent(samples, 880, at, at + .04, .0425,
      "Reused2× original lost a40ms body window");
    const doubled = component(samples, 1760, at, at + .04);
    assert(peak.level > doubled * 2, "Reused2× source must preserve880Hz original pitch");
    return {at, peak, doubled};
  }));
  const voiceReference = component(samples, 660, .7, .8);
  assert(voiceReference > .15, "Offline middle photo must retain the selected narration");
  const voice = [.3, .7, 1.2].map(at => ({at, level: component(samples, 660, at, at + .1)}));
  assert(voice.every(value => value.level > voiceReference * .7), "Narration shifted between live and offline windows");
  const boundaryVoice = [.48, .98].map(at => ({at, level: component(samples, 660, at, at + .04)}));
  assert(boundaryVoice.every(value => value.level > voiceReference * .5), "Narration developed a hybrid boundary seam");
  const voiceBefore = component(samples, 660, .02, .08), voiceAfter = component(samples, 660, 1.4, 1.48);
  assert(voiceBefore < voiceReference * .08 && voiceAfter < voiceReference * .08,
    "Short narration must preserve its.15s offset and1.35s end");
  const middleOriginal = {opening: component(samples, 990, .65, .85), body: component(samples, 880, .65, .85)};
  assert(middleOriginal.opening < .003 && middleOriginal.body < .003,
    "Offline middle photo must not retain either original-video tone");
  const shots = [.3, .7, 1.3].map(at => ({at, rgb: rgb(file, at)}));
  for (const [index, shot] of shots.entries()) index === 1 ?
    assert(shot.rgb[0] > 205 && shot.rgb[1] < 35 && shot.rgb[2] < 35) :
    assert(shot.rgb[0] < 10 && shot.rgb[1] < 10 && shot.rgb[2] > 240);
  return {...result, markers, body, voiceReference, voice, boundaryVoice, voiceBefore, voiceAfter, middleOriginal, shots};
}
