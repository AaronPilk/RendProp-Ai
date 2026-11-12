// Exact, finite PCM windows. The main thread returns each transferred buffer
// only after the encoder accepts that block; missing credit refuses capture.
const RATE = 48_000;
const CHANNELS = 2;
const BLOCK = 1024;
const CREDITS = 8;
const LEAD = 8192;
const MAX_FRAMES = 180 * RATE;

class RendpropExportPCMTap extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const initialIndex = options?.processorOptions?.initialIndex;
    const initialBase = options?.processorOptions?.initialBase;
    this.stopped = false;
    this.faulted = false;
    this.armed = false;
    this.windowIndex = initialIndex - 1;
    this.nextIndex = initialIndex;
    this.expectedBase = initialBase;
    this.outputBase = 0;
    this.windowFrames = 0;
    this.startFrame = -1;
    this.endFrame = -1;
    this.relativeFrame = 0;
    this.sequence = 0;
    this.blockFrames = 0;
    this.blockStart = 0;
    this.outstanding = 0;
    this.pool = Array.from({length: CREDITS},
      () => new Float32Array(CHANNELS * BLOCK));
    this.current = this.pool.pop();
    this.port.onmessage = ({data}) => {
      if (data?.type === "arm") this.arm(data);
      else if (data?.type === "recycle") this.recycle(data);
      else if (data?.type === "stop") this.stopped = true;
      else this.fault("invalid-control");
    };
    if (!Number.isSafeInteger(initialIndex) || initialIndex < 0 || initialIndex >= 12 ||
        !Number.isSafeInteger(initialBase) || initialBase < 0 ||
        initialBase >= MAX_FRAMES)
      this.fault("invalid-initial-window");
  }

  fault(code) {
    if (this.faulted || this.stopped) return;
    this.faulted = true;
    this.port.postMessage({type: "fault", code, windowIndex: this.windowIndex,
      sampleFrame: currentFrame, relativeFrame: this.relativeFrame,
      sequence: this.sequence, outstanding: this.outstanding,
      conservedCredits: this.outstanding + this.pool.length + Number(Boolean(this.current))});
  }

  arm(row) {
    if (this.stopped || this.faulted || this.armed || sampleRate !== RATE ||
        !Number.isSafeInteger(row.windowIndex) || row.windowIndex !== this.nextIndex ||
        !Number.isSafeInteger(row.outputBase) || row.outputBase !== this.expectedBase ||
        !Number.isSafeInteger(row.frameCount) || row.frameCount < 1 ||
        row.frameCount > MAX_FRAMES || row.outputBase + row.frameCount > MAX_FRAMES ||
        this.outstanding !== 0 || this.blockFrames !== 0 ||
        !this.current || this.pool.length !== CREDITS - 1) {
      this.fault("invalid-window-rearm");
      return;
    }
    this.windowIndex = row.windowIndex;
    this.outputBase = row.outputBase;
    this.windowFrames = row.frameCount;
    this.relativeFrame = 0;
    this.sequence = 0;
    this.startFrame = currentFrame + LEAD;
    this.endFrame = this.startFrame + this.windowFrames;
    this.armed = true;
    this.port.postMessage({type: "armed", windowIndex: this.windowIndex,
      outputBase: this.outputBase, frameCount: this.windowFrames,
      sampleRate, channels: CHANNELS, blockFrames: BLOCK, credits: CREDITS,
      startFrame: this.startFrame, endFrame: this.endFrame});
  }

  recycle(row) {
    if (this.stopped || this.faulted || !(row.buffer instanceof ArrayBuffer) ||
        row.buffer.byteLength !== CHANNELS * BLOCK * 4 || this.outstanding < 1) {
      this.fault("invalid-credit-return");
      return;
    }
    this.outstanding--;
    this.pool.push(new Float32Array(row.buffer));
    if (!this.current) this.current = this.pool.pop();
    if (this.pool.length + Number(Boolean(this.current)) + this.outstanding !== CREDITS)
      this.fault("credit-conservation");
  }

  flush() {
    if (!this.current || this.blockFrames < 1) {
      this.fault("missing-block");
      return;
    }
    const buffer = this.current.buffer;
    this.port.postMessage({type: "chunk", windowIndex: this.windowIndex,
      outputBase: this.outputBase, sequence: this.sequence,
      startFrame: this.blockStart, frameCount: this.blockFrames,
      channels: CHANNELS, buffer}, [buffer]);
    this.sequence++;
    this.outstanding++;
    this.blockFrames = 0;
    this.current = this.pool.pop() ?? null;
    if (this.pool.length + Number(Boolean(this.current)) + this.outstanding !== CREDITS)
      this.fault("credit-conservation");
  }

  process(inputs, outputs) {
    const input = inputs[0] ?? [];
    const output = outputs[0] ?? [];
    for (let channel = 0; channel < output.length; channel++) {
      const from = input[channel] ?? input[0];
      if (from) output[channel].set(from);
      else output[channel].fill(0);
    }
    if (this.stopped) return false;
    if (!this.armed || this.faulted) return true;
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
        if (!this.faulted && this.relativeFrame === this.windowFrames) {
          this.armed = false;
          this.nextIndex++;
          this.expectedBase += this.windowFrames;
          this.port.postMessage({type: "done", windowIndex: this.windowIndex,
            outputBase: this.outputBase, frames: this.relativeFrame,
            blocks: this.sequence, outstanding: this.outstanding,
            nextOutputBase: this.expectedBase});
        } else this.fault("window-frame-count");
        break;
      }
      if (!this.current) {this.fault("pcm-credit-exhausted"); break;}
      if (this.blockFrames === 0) this.blockStart = this.relativeFrame;
      for (let channel = 0; channel < CHANNELS; channel++) {
        const value = input[channel][offset];
        if (!Number.isFinite(value)) {this.fault("nonfinite-pcm"); break;}
        this.current[channel * BLOCK + this.blockFrames] = value;
      }
      if (this.faulted) break;
      this.blockFrames++;
      this.relativeFrame++;
      if (this.blockFrames === BLOCK) this.flush();
      if (this.faulted) break;
    }
    return true;
  }
}
registerProcessor("rendprop-export-pcm-tap", RendpropExportPCMTap);
