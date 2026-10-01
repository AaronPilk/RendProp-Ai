// Explicit paid quality experiment; never part of automatic tests or CI.
// Four calls maximum, sequential, same image/model and real assembled prompts.
import { geminiAdapter } from "../../../../services/supabase/functions/_shared/providers/gemini.ts";
import type { RouteStep } from "../../../../services/supabase/functions/_shared/router.ts";
const [directory, fixture] = Deno.args;
if (!directory?.includes("rendprop-photo-quality-") || !fixture?.endsWith("example-staging-before.webp")) throw new Error("Owned evidence/fixture required");
const cases = JSON.parse(await Deno.readTextFile(`${directory}/prompts.json`));
if (cases.length !== 4) throw new Error("Exactly four fixed comparisons required");
if (cases.some((item: any) => !["8d32f85", "7bcc624"].includes(item.revision) ||
    !["declutter", "stage"].includes(item.edit) ||
    (item.replicate != null && ![1, 2].includes(item.replicate)))) throw new Error("Unexpected comparison case");
// A partially completed paid experiment must not repeat calls on rerun.
const intent = await Deno.open(`${directory}/started`, { write: true, createNew: true });
intent.close();
const bytes = await Deno.readFile(fixture);
let binary = "";
for (const byte of bytes) binary += String.fromCharCode(byte);
const model = "gemini-3.1-flash-image";
const receipts: Record<string, unknown>[] = [];
let providerMetadata: unknown = null;
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const target = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url);
  if (target.origin !== "https://generativelanguage.googleapis.com" || !target.pathname.endsWith(`/${model}:generateContent`)) throw new Error("Unexpected provider destination");
  const response = await originalFetch(input, init);
  const body = await response.clone().json().catch(() => ({}));
  providerMetadata = { http_status: response.status, usage: body.usageMetadata ?? null,
    response_id: body.responseId ?? null, model_version: body.modelVersion ?? null };
  return response;
};
for (const item of cases) {
  const started = Date.now();
  const receipt: Record<string, unknown> = { revision: item.revision, edit: item.edit, replicate: item.replicate, model,
    configured_unit_cents: 6.7, invoice_cost: null, started_at: new Date().toISOString() };
  providerMetadata = null;
  try {
    const step = { provider: "gemini", model } as RouteStep;
    const job = await geminiAdapter.submit(step, { task: `photo.${item.edit}`, prompt: item.prompt,
      image_b64: btoa(binary), extra: { image_mime: "image/webp" } });
    const done = await geminiAdapter.poll(job);
    if (done.status !== "done" || !done.result_url.startsWith("data:image/")) throw new Error("Provider produced no image");
    const mime = done.mime;
    const data = Uint8Array.from(atob(done.result_url.split(",")[1]), c => c.charCodeAt(0));
    const name = `${item.edit}-${item.revision}${item.replicate ? `-replicate-${item.replicate}` : ""}.${mime === "image/jpeg" ? "jpg" : "png"}`;
    await Deno.writeFile(`${directory}/${name}`, data);
    receipt.output = name;
    receipt.bytes = data.length;
    receipt.completed = true;
  } catch (error) {
    // No request headers, credentials, data URLs or raw provider response logs.
    receipt.completed = false;
    receipt.error_type = error instanceof Error ? error.name : "Error";
  }
  receipt.elapsed_s = (Date.now() - started) / 1000;
  receipt.provider = providerMetadata;
  receipts.push(receipt);
  await Deno.writeTextFile(`${directory}/receipt.json`, JSON.stringify({ fixture,
    scope: "Actual handler prompts and Gemini adapter; fixed public demo; no production state mutations", receipts }, null, 2));
  console.log(JSON.stringify({ revision: item.revision, edit: item.edit, completed: receipt.completed, elapsed_s: receipt.elapsed_s }));
}
