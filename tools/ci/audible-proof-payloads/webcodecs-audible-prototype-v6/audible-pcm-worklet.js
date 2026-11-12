/* External three-second diagnostic only. The audio render thread never waits on AAC. */
const RATE = 48000;
const CHANNELS = 2;
const BLOCK = 1024;
const CREDITS = 8;
const WINDOW = 3 * RATE;
const LEAD = 8192;
const epochNow = () => {
  try {
    return typeof Date !== "undefined" && typeof Date.now === "function" ? Date.now() : null;
  } catch { return null; }
};

class RendpropAudibleProofTap extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.faultMode = options?.processorOptions?.faultMode ?? "none";
    if (!["none", "drop-first-block", "withhold-credits"].includes(this.faultMode))
      throw new Error("Invalid diagnostic fault mode");
    this.armed = false;
    this.done = false;
    this.faulted = false;
    this.startFrame = -1;
    this.endFrame = -1;
    this.relativeFrame = 0;
    this.sequence = 0;
    this.blockFrames = 0;
    this.blockStart = 0;
    this.outstanding = 0;
    this.pool = Array.from({length: CREDITS}, () => new Float32Array(CHANNELS * BLOCK));
    this.current = this.pool.pop();
    // Passive credit accounting for the disposable diagnostic only. Every
    // sent block must be either outstanding or back in current/the pool.
    this.totalRecycles = 0;
    this.maxOutstanding = 0;
    this.maxPoolLength = this.pool.length;
    this.lastRecycleFrame = -1;
    this.lastFlushFrame = -1;
    this.lastRecycleEpochMs = null;
    this.lastFlushEpochMs = null;
    this.port.onmessage = ({data}) => {
      if (data?.type === "arm") {
        if (this.armed || this.done || this.faulted || sampleRate !== RATE) {
          this.fault("invalid-arm-or-sample-rate");
          return;
        }
        this.armed = true;
        this.startFrame = currentFrame + LEAD;
        this.endFrame = this.startFrame + WINDOW;
        this.port.postMessage({
          type: "armed", sampleRate, startFrame: this.startFrame,
          endFrame: this.endFrame, channels: CHANNELS,
          blockFrames: BLOCK, credits: CREDITS,
        });
      } else if (data?.type === "recycle") {
        if (!(data.buffer instanceof ArrayBuffer) ||
            data.buffer.byteLength !== CHANNELS * BLOCK * 4 ||
            this.outstanding < 1) {
          this.fault("invalid-credit-return");
          return;
        }
        this.outstanding--;
        this.totalRecycles++;
        this.lastRecycleFrame = currentFrame;
        this.lastRecycleEpochMs = epochNow();
        this.pool.push(new Float32Array(data.buffer));
        this.maxPoolLength = Math.max(this.maxPoolLength, this.pool.length);
        if (!this.current) this.current = this.pool.pop();
      } else if (data?.type === "stop") {
        this.done = true;
      } else {
        this.fault("invalid-control");
      }
    };
  }

  fault(code) {
    if (this.faulted || this.done) return;
    this.faulted = true;
    this.port.postMessage({type: "fault", code, relativeFrame: this.relativeFrame,
      sequence: this.sequence, outstanding: this.outstanding,
      sampleFrame: currentFrame, credits: CREDITS,
      totalRecycles: this.totalRecycles, maxOutstanding: this.maxOutstanding,
      poolLength: this.pool.length, maxPoolLength: this.maxPoolLength,
      currentPresent: Boolean(this.current),
      conservedCredits: this.pool.length + Number(Boolean(this.current)) + this.outstanding,
      lastRecycleFrame: this.lastRecycleFrame, lastFlushFrame: this.lastFlushFrame,
      lastRecycleEpochMs: this.lastRecycleEpochMs,
      lastFlushEpochMs: this.lastFlushEpochMs, faultEpochMs: epochNow()});
  }

  flush() {
    if (!this.current || this.blockFrames < 1) {
      this.fault("missing-block");
      return;
    }
    if (this.faultMode === "drop-first-block" && this.sequence === 0) {
      this.sequence++;
      this.blockFrames = 0;
      return;
    }
    const buffer = this.current.buffer;
    this.port.postMessage({
      type: "chunk", sequence: this.sequence++, startFrame: this.blockStart,
      frameCount: this.blockFrames, channels: CHANNELS, buffer,
    }, [buffer]);
    this.outstanding++;
    this.maxOutstanding = Math.max(this.maxOutstanding, this.outstanding);
    this.lastFlushFrame = currentFrame;
    this.lastFlushEpochMs = epochNow();
    this.blockFrames = 0;
    this.current = this.pool.pop() ?? null;
  }

  process(inputs, outputs) {
    const input = inputs[0] ?? [];
    const output = outputs[0] ?? [];
    for (let channel = 0; channel < output.length; channel++) {
      const from = input[channel] ?? input[0];
      if (from) output[channel].set(from);
      else output[channel].fill(0);
    }
    if (!this.armed || this.done || this.faulted) return !this.done;
    const frames = output[0]?.length ?? 128;
    if (currentFrame + frames > this.startFrame && currentFrame < this.endFrame &&
        (input.length !== CHANNELS || output.length !== CHANNELS ||
          input.some(channel => channel.length !== frames) ||
          output.some(channel => channel.length !== frames))) {
      this.fault("missing-stereo-input");
      return true;
    }
    for (let offset = 0; offset < frames; offset++) {
      const absolute = currentFrame + offset;
      if (absolute < this.startFrame) continue;
      if (absolute >= this.endFrame) {
        if (this.blockFrames) this.flush();
        if (!this.faulted && this.relativeFrame === WINDOW) {
          this.done = true;
          this.port.postMessage({type: "done", frames: this.relativeFrame,
            blocks: this.sequence, outstanding: this.outstanding});
        } else this.fault("window-frame-count");
        break;
      }
      if (!this.current) {
        this.fault("pcm-credit-exhausted");
        break;
      }
      if (this.blockFrames === 0) this.blockStart = this.relativeFrame;
      for (let channel = 0; channel < CHANNELS; channel++) {
        const sample = input[channel][offset];
        if (!Number.isFinite(sample)) {
          this.fault("nonfinite-pcm");
          break;
        }
        this.current[channel * BLOCK + this.blockFrames] = sample;
      }
      if (this.faulted) break;
      this.blockFrames++;
      this.relativeFrame++;
      if (this.blockFrames === BLOCK) this.flush();
      if (this.faulted) break;
    }
    return !this.done;
  }
}
registerProcessor("rendprop-audible-proof-tap", RendpropAudibleProofTap);
