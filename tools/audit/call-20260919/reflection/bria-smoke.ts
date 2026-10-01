// Manual paid provider check, never CI. Exactly one submit; an existing receipt
// is polled without resubmission. Input must be a local, non-customer <5s clip.
import { ERASE_MODEL, ERASE_PROMPT } from "../../../../services/supabase/functions/ai-video/erase.ts";
import { probeMP4Duration } from "../../../../services/supabase/functions/ai-video/mp4duration.ts";

const [input, outputDirectory] = Deno.args;
if (!input || !outputDirectory) throw new Error("Pass input.mp4 and private evidence directory");
const key = Deno.env.get("FAL_KEY");
if (!key) throw new Error("FAL_KEY must be present, never printed");
await Deno.mkdir(outputDirectory, { recursive: true });
const receiptPath = outputDirectory + "/receipt.json";
let receipt: Record<string, any>;
try { receipt = JSON.parse(await Deno.readTextFile(receiptPath)); }
catch (error) {
  if (!(error instanceof Deno.errors.NotFound)) throw error;
  receipt = { model: ERASE_MODEL, fixture: input, submitted: false,
    unit_usd_per_second: 0.14, configured_duration_s: 3, rate_based_cost_usd: 0.42,
    invoiced_cost_usd: null, prompt: ERASE_PROMPT };
}
async function save() {
  await Deno.writeTextFile(receiptPath + ".tmp", JSON.stringify(receipt, null, 2) + "\n");
  await Deno.rename(receiptPath + ".tmp", receiptPath);
}
async function queue(url: string, init: RequestInit = {}) {
  const parsed = new URL(url);
  if (parsed.origin !== "https://queue.fal.run" || !parsed.pathname.startsWith("/bria/") || parsed.username || parsed.password) {
    throw new Error("Untrusted queue URL");
  }
  return await fetch(url, { ...init, redirect: "error", signal: AbortSignal.timeout(30000),
    headers: { "Authorization": "Key " + key, "Content-Type": "application/json" } });
}
if (!receipt.submitted) {
  const bytes = await Deno.readFile(input);
  if (bytes.length > 8_000_000) throw new Error("Use a bounded synthetic fixture");
  const duration = await probeMP4Duration("https://fixture.invalid/video.mp4", async (_url, init) => {
    const range = new Headers(init.headers).get("range");
    const match = /^bytes=(\d+)-(\d+)$/.exec(range ?? "");
    if (!match) throw new Error("Expected a bounded metadata read");
    const first = Number(match[1]), last = Number(match[2]);
    if (last >= bytes.length) return new Response(null, { status: 416 });
    return new Response(bytes.slice(first, last + 1), { status: 206,
      headers: { "content-range": `bytes ${first}-${last}/${bytes.length}` } });
  });
  if (Math.abs(duration - 3) > 0.001) throw new Error("This bounded smoke authorizes exactly a3-second fixture");
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  receipt.submitted = true; // A crash after this point must never cause a second paid POST.
  receipt.started_at = new Date().toISOString();
  receipt.input_sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map(v => v.toString(16).padStart(2, "0")).join("");
  await save();
  try {
    const response = await queue("https://queue.fal.run/" + ERASE_MODEL, { method: "POST", body: JSON.stringify({
      video_url: "data:video/mp4;base64," + btoa(binary), prompt: ERASE_PROMPT,
      auto_trim: false, preserve_audio: true, output_container_and_codec: "mp4_h264",
    }) });
    receipt.submit_http_status = response.status;
    receipt.ref = await response.json();
    await save();
    if (!response.ok) throw new Error("Provider rejected submission; inspect receipt, do not retry");
  } catch (error) {
    receipt.submit_error = error instanceof Error ? error.message : "unknown";
    await save();
    throw new Error("Submission did not complete cleanly; no automatic retry");
  }
}
if (!receipt.ref?.status_url || !receipt.ref?.response_url) throw new Error("No durable provider reference; do not resubmit");
console.log(JSON.stringify({ request_id: receipt.ref.request_id, rate_based_cost_usd: receipt.rate_based_cost_usd }));
const deadline = Date.now() + 30 * 60 * 1000;
while (!receipt.finished && Date.now() < deadline) {
  const response = await queue(receipt.ref.status_url);
  receipt.last_status = await response.json();
  receipt.last_checked_at = new Date().toISOString();
  await save();
  if (!response.ok) throw new Error("Status request failed; rerun to resume polling only");
  const status = receipt.last_status.status;
  console.log(JSON.stringify({ status }));
  if (["COMPLETED", "FAILED", "CANCELLED"].includes(status)) {
    const result = await queue(receipt.ref.response_url);
    receipt.result_http_status = result.status;
    receipt.result = await result.json();
    receipt.finished = true;
    receipt.completed = result.ok && !!receipt.result.video?.url;
    receipt.finished_at = new Date().toISOString();
    await save();
    break;
  }
  await new Promise(resolve => setTimeout(resolve, 10000));
}
if (receipt.completed) {
  const url = new URL(receipt.result.video.url);
  if (url.protocol !== "https:" || !(url.hostname === "fal.media" || url.hostname.endsWith(".fal.media"))) throw new Error("Unexpected media host");
  const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error("Output download failed; retry polling script without another submit");
  const bytes = new Uint8Array(await response.arrayBuffer());
  await Deno.writeFile(outputDirectory + "/edited.mp4", bytes);
  receipt.output_bytes = bytes.length;
  receipt.output_sha256 = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map(v => v.toString(16).padStart(2, "0")).join("");
  await save();
}
console.log(JSON.stringify({ completed: receipt.completed ?? false, receipt: receiptPath }));
