const RATE = 48_000;

/** Web Audio compares automation times as doubles, without sample rounding. */
export function disjointMusicCurve(startFrame: number, frameCount: number): {
  startSeconds: number; durationSeconds: number;
} {
  if (!Number.isSafeInteger(startFrame) || !Number.isSafeInteger(frameCount) ||
      startFrame < 0 || frameCount < 1 || startFrame + frameCount > 180 * RATE)
    throw new Error("The music window is invalid. No download was created.");
  const startSeconds = startFrame / RATE;
  const endSeconds = (startFrame + frameCount) / RATE;
  // Independent divisions can make start + frameCount/RATE round one ULP past
  // the next window's start. Reserve only a floating-point guard; PCM windows
  // and their exact sample counts remain unchanged.
  const durationSeconds = endSeconds - startSeconds -
    Number.EPSILON * Math.max(1, endSeconds);
  if (durationSeconds <= 0 || startSeconds + durationSeconds > endSeconds)
    throw new Error("The music automation window is invalid. No download was created.");
  return {startSeconds, durationSeconds};
}
