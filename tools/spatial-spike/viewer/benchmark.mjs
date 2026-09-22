// A RAF callback is not evidence that the renderer drew the room. Only callers
// that observed a nonempty onscreen splat draw may submit a rendered frame.
export class RenderBenchmark {
  constructor({ warmupMs = 5000, sampleMs = 30000 } = {}) {
    if (!Number.isFinite(warmupMs) || !Number.isFinite(sampleMs) || warmupMs < 0 || sampleMs <= 0) throw new Error('Invalid measurement duration');
    this.warmupMs = warmupMs;
    this.sampleMs = sampleMs;
    this.state = 'idle';
  }

  start({ ready, visible, deviceLabel }, now) {
    if (!Number.isFinite(now)) throw new Error('Invalid render clock');
    if (!ready) throw new Error('Load a nonempty SOG before measuring');
    if (!visible) throw new Error('Keep this page visible');
    if (!deviceLabel?.trim()) throw new Error('Enter the actual device, OS, and browser');
    this.deviceLabel = deviceLabel.trim();
    this.state = 'warming';
    this.requestedAt = now;
    this.firstDrawAt = null;
    this.sampleStart = null;
    this.previousDraw = null;
    this.intervals = [];
    this.reason = null;
    this.lastDrawAt = now;
    this.result = null;
  }

  get active() { return this.state === 'warming' || this.state === 'measuring'; }

  invalidate(reason) {
    if (!this.active) return;
    this.state = 'invalid';
    this.reason = reason;
    this.result = { valid: false, reason, fps: null, deviceLabel: this.deviceLabel };
  }

  tick(now, visible) {
    if (!this.active) return;
    if (!Number.isFinite(now)) return this.invalidate('Invalid render clock');
    if (!visible) return this.invalidate('Page was hidden; restart the measurement');
    if (now - this.lastDrawAt > 10000) this.invalidate('No nonempty onscreen splat draw for 10 seconds');
  }

  rendered(now, { visible, onscreenDraws, splatCount }) {
    this.tick(now, visible);
    if (!this.active || !(onscreenDraws > 0 && splatCount > 0)) return;
    if (!Number.isFinite(now) || now < this.lastDrawAt) return this.invalidate('Nonmonotonic render clock');
    this.lastDrawAt = now;
    if (this.firstDrawAt === null) this.firstDrawAt = now;
    if (this.state === 'warming') {
      if (now - this.firstDrawAt < this.warmupMs) return;
      this.state = 'measuring';
      this.sampleStart = now;
      this.previousDraw = now;
      return;
    }
    const interval = now - this.previousDraw;
    if (interval <= 0) return;
    this.intervals.push(interval);
    this.previousDraw = now;
    const elapsedMs = now - this.sampleStart;
    if (elapsedMs < this.sampleMs) return;
    const sorted = [...this.intervals].sort((a, b) => a - b);
    const percentile = (p) => sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)];
    this.state = 'complete';
    this.result = {
      valid: true,
      deviceLabel: this.deviceLabel,
      warmupMs: this.warmupMs,
      elapsedMs,
      renderedFrames: this.intervals.length + 1,
      measuredIntervals: this.intervals.length,
      fps: this.intervals.length * 1000 / elapsedMs,
      medianFrameIntervalMs: percentile(0.5),
      p95FrameIntervalMs: percentile(0.95),
      maxFrameIntervalMs: sorted.at(-1),
      frameIntervalsMs: [...this.intervals]
    };
  }
}

export function assertSogEnvelope(name, bytes) {
  if (!name.toLowerCase().endsWith('.sog')) throw new Error('Choose a bundled .sog file');
  const a = new Uint8Array(bytes);
  if (a.length < 22 || a[0] !== 0x50 || a[1] !== 0x4b || a[2] !== 3 || a[3] !== 4) {
    throw new Error('This is not a bundled SOG ZIP file');
  }
  // This is an envelope check only. PlayCanvas must still decode and validate
  // metadata/textures; a ZIP signature by itself never enables measurement.
}
