const PCM_BLOCK_BYTES = 2 * 1024 * Float32Array.BYTES_PER_ELEMENT;

type PCMEncoder = {
  addAudio(buffer: ArrayBuffer, startFrame: number, frameCount: number): Promise<ArrayBuffer>;
};

/** Send one fixed-stride PCM block without reading its detached sender afterward. */
export async function sendOwnedPCMBlock(encoder: PCMEncoder, buffer: ArrayBuffer,
  startFrame: number, frameCount: number): Promise<void> {
  if (buffer.byteLength !== PCM_BLOCK_BYTES)
    throw new Error("The audio block has an invalid size. No download was created.");
  const returned = await encoder.addAudio(buffer, startFrame, frameCount);
  if (!(returned instanceof ArrayBuffer) || returned.byteLength !== PCM_BLOCK_BYTES)
    throw new Error("The audio encoder did not return its buffer. No download was created.");
}
