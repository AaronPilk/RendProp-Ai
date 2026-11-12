/** Owned Web Audio clock, opened synchronously during the Export gesture. */
export type ExportAudioBootstrap = {
  context: AudioContext;
  sink: MediaStreamAudioDestinationNode;
  resumeStarted: Promise<void>;
  stop(): void;
  close(): Promise<void>;
};

export class ExportAudioBootstrapSetupError extends Error {
  constructor(readonly closeStarted: Promise<void>, cause: unknown) {
    super("The browser could not start the export audio clock.", {cause});
  }
}

/** Observe a failed setup close without losing its original failure. */
export async function observeBootstrapSetup(error: ExportAudioBootstrapSetupError): Promise<never> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const result = await Promise.race([
    error.closeStarted.then(() => "closed" as const, () => "failed" as const),
    new Promise<"timed-out">(resolve => {timer = setTimeout(() => resolve("timed-out"), 2000);}),
  ]);
  if (timer !== undefined) clearTimeout(timer);
  if (result !== "closed")
    throw new Error("The export audio clock could not close after setup failed. No download was created.", {cause: error});
  throw error.cause ?? error;
}

/** The zero source keeps the one owned stream sink active before user content begins. */
export function beginExportAudio(): ExportAudioBootstrap {
  const context = new AudioContext({sampleRate: 48_000});
  let sink: MediaStreamAudioDestinationNode | undefined;
  let zero: ConstantSourceNode | undefined;
  let started = false;
  const stopOwned = () => {
    let failed: unknown;
    if (started) {
      try {zero?.stop();} catch (error) {failed ??= error;}
      started = false;
    }
    try {zero?.disconnect();} catch (error) {failed ??= error;}
    try {sink?.stream.getTracks().forEach(track => track.stop());}
    catch (error) {failed ??= error;}
    if (failed) throw failed;
  };
  let resumeStarted: Promise<void>;
  try {
    sink = context.createMediaStreamDestination();
    zero = context.createConstantSource();
    zero.offset.value = 0;
    zero.connect(sink);
    zero.start();
    started = true;
    resumeStarted = context.resume();
  } catch (error) {
    try {stopOwned();} catch { /* Preserve setup cause. */ }
    let closeStarted: Promise<void>;
    try {closeStarted = context.close();}
    catch (closeError) {closeStarted = Promise.reject(closeError);}
    void closeStarted.catch(() => undefined);
    throw new ExportAudioBootstrapSetupError(closeStarted, error);
  }
  void resumeStarted.catch(() => undefined);
  let stopped = false;
  let closePromise: Promise<void> | undefined;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    stopOwned();
  };
  const close = () => closePromise ??= (async () => {
    let stopError: unknown;
    try {stop();} catch (error) {stopError = error;}
    if (context.state !== "closed") {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const result = await Promise.race([
        context.close().then(() => true, () => false),
        new Promise<false>(resolve => {timer = setTimeout(() => resolve(false), 2000);}),
      ]);
      if (timer !== undefined) clearTimeout(timer);
      const currentState = (): AudioContextState => context.state;
      if (!result || currentState() !== "closed")
        throw new Error("The export audio clock did not close. No download was created.", {cause: stopError});
    }
    if (stopError) throw stopError;
  })();
  return {context, sink, resumeStarted, stop, close};
}
