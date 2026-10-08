// Test-only measurements of the fixture's declared AAC timeline. Never search
// decoded levels to choose a more favorable fade window.
const AAC_FRAME_SAMPLES = 1024;
export const PCM_RATE = 48000;
export const PROBE_SECONDS = .15;

function finiteNumber(value, label) {
  if (!(typeof value === "number" || typeof value === "string" && /^-?\d+(?:\.\d+)?$/.test(value)))
    throw new Error(`Invalid ${label}`);
  const number = Number(value);
  if (!Number.isFinite(number)) throw new Error(`Invalid ${label}`);
  return number;
}

export function fixedAACTailWindow(probe, nominalSeconds) {
  if (!Number.isFinite(nominalSeconds) || nominalSeconds <= 0)
    throw new Error("Invalid intended audio duration");
  const streams = probe?.streams?.filter(stream => stream.codec_type === "audio");
  if (streams?.length !== 1 || streams[0].codec_name !== "aac")
    throw new Error("Exactly one declared AAC audio stream is required");
  const audio = streams[0];
  const sampleRate = finiteNumber(audio.sample_rate, "AAC sample rate");
  if (sampleRate !== PCM_RATE)
    throw new Error("Invalid AAC sample rate");
  // One frame for encoder priming and one for final packet quantization. This
  // small codec allowance cannot hide a materially shortened soundtrack.
  const codecTolerance = 2 * AAC_FRAME_SAMPLES / sampleRate;
  const start = finiteNumber(audio.start_time, "AAC start");
  const duration = finiteNumber(audio.duration, "AAC duration");
  const end = start + duration;
  const formatDuration = finiteNumber(probe.format?.duration, "container duration");
  if (duration <= 0 || Math.abs(start) > codecTolerance ||
      duration < nominalSeconds - codecTolerance || end < nominalSeconds - codecTolerance)
    throw new Error("AAC audio does not cover the intended edit");
  if (!Number.isFinite(end) || Math.abs(formatDuration - nominalSeconds) >= .5 ||
      end > formatDuration + codecTolerance)
    throw new Error("Invalid AAC/container endpoint");
  const probeStart = end - .2;
  if (probeStart < start) throw new Error("AAC tail cannot contain the full probe window");
  return {start, duration, end, sampleRate, codecTolerance, nominalSeconds,
    formatDuration, probeStart, probeEnd: probeStart + PROBE_SECONDS};
}

export function measureTonePCM(bytes, frequency) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length % 4)
    throw new Error("PCM window is empty or malformed");
  const count = bytes.length / 4;
  const expected = PROBE_SECONDS * PCM_RATE;
  if (count < Math.floor(expected) - 1 || count > Math.ceil(expected) + AAC_FRAME_SAMPLES)
    throw new Error("PCM window does not contain the full requested duration");
  if (!Number.isFinite(frequency) || frequency <= 0 || frequency >= PCM_RATE / 2)
    throw new Error("Invalid probe frequency");
  let real = 0, imaginary = 0, energy = 0;
  for (let index = 0; index < count; index++) {
    const sample = bytes.readFloatLE(index * 4);
    if (!Number.isFinite(sample)) throw new Error("PCM window contains nonfinite samples");
    real += sample * Math.cos(2 * Math.PI * frequency * index / PCM_RATE);
    imaginary += sample * Math.sin(2 * Math.PI * frequency * index / PCM_RATE);
    energy += sample * sample;
  }
  const amplitude = 2 * Math.hypot(real, imaginary) / count;
  const rms = Math.sqrt(energy / count);
  if (!Number.isFinite(amplitude) || !Number.isFinite(rms) || rms === 0)
    throw new Error("PCM window must contain finite audible audio");
  return {sampleCount: count, decodedSeconds: count / PCM_RATE, amplitude, rms};
}

export function requireAudibleFadeOut(tailAmplitude, referenceAmplitude) {
  // This fixture has a one-second linear fade and samples its last200–50ms.
  // Requiring at least1% of its steady tone rejects silence/codec residue;
  // the original upper bound of half the reference remains unchanged.
  if (!Number.isFinite(tailAmplitude) || !Number.isFinite(referenceAmplitude) ||
      referenceAmplitude <= Number.EPSILON || tailAmplitude <= referenceAmplitude * .01)
    throw new Error("Fade-out must contain audible music, not encoded silence");
  if (!(tailAmplitude < referenceAmplitude * .5))
    throw new Error("Fade-out must remain below half of the audible music reference");
}
