/* External v6 experiment only. Mirrors shipping's early zero -> stream sink. */
export type SilentStreamTrace = {
  kind: "early-silent-stream-bootstrap";
  connectedToStreamSink: boolean;
  started: boolean;
  stopCalls: number;
  disconnected: boolean;
  tracksCreated: number;
  liveTracksAfterStop: number | null;
  createdWallMs: number;
  createdAudioSeconds: number | null;
  startedWallMs: number | null;
  startedAudioSeconds: number | null;
  stoppedWallMs: number | null;
};

export function startSilentStreamBootstrap(audio: AudioContext) {
  const audioSeconds = () => {
    try {return Number.isFinite(audio.currentTime) ? audio.currentTime : null;}
    catch {return null;}
  };
  const trace: SilentStreamTrace = {
    kind: "early-silent-stream-bootstrap", connectedToStreamSink: false,
    started: false, stopCalls: 0, disconnected: false,
    tracksCreated: 0, liveTracksAfterStop: null,
    createdWallMs: performance.now(), createdAudioSeconds: audioSeconds(),
    startedWallMs: null, startedAudioSeconds: null, stoppedWallMs: null,
  };
  let sink: MediaStreamAudioDestinationNode | undefined;
  let source: ConstantSourceNode | undefined;
  const stopTracks = () => {
    sink?.stream.getTracks().forEach(track => track.stop());
    trace.liveTracksAfterStop = sink?.stream.getTracks()
      .filter(track => track.readyState !== "ended").length ?? 0;
  };
  try {
    sink = audio.createMediaStreamDestination();
    trace.tracksCreated = sink.stream.getTracks().length;
    source = audio.createConstantSource();
    source.offset.value = 0;
    source.connect(sink);
    trace.connectedToStreamSink = true;
    source.start();
    trace.started = true;
    trace.startedWallMs = performance.now();
    trace.startedAudioSeconds = audioSeconds();
  } catch (error) {
    // A failed start may still have side effects; stop if the source exists.
    try {source?.stop();} catch { /* Preserve original setup failure. */ }
    try {source?.disconnect(); trace.disconnected = true;}
    catch { /* Preserve original setup failure. */ }
    try {stopTracks();} catch { /* Preserve original setup failure. */ }
    trace.stoppedWallMs = performance.now();
    throw error;
  }
  let stopped = false;
  const stop = () => {
    trace.stopCalls++;
    if (stopped) return;
    stopped = true;
    let firstError: unknown;
    try {source?.stop();} catch (error) {firstError = error;}
    try {source?.disconnect(); trace.disconnected = true;}
    catch (error) {firstError ??= error;}
    try {stopTracks();} catch (error) {firstError ??= error;}
    trace.stoppedWallMs = performance.now();
    if (firstError) throw firstError;
  };
  return {sink: sink!, trace, stop};
}
