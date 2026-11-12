import { assertEquals, assertInstanceOf, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError, respondError } from "../_shared/http.ts";
import { uploadRPC } from "./transport.ts";

async function refused(message: string) {
  try {
    await uploadRPC({ rpc: async () => ({ data: null, error: { message } }) },
      "reserve_upload_assets", {});
    throw new Error("Admission refusal must fail");
  } catch (error) {
    assertInstanceOf(error, HttpError);
    return { error, response: respondError(error) };
  }
}

for (const [code, status, expected] of [
  ["RP401", 401, "unauthorized"], ["RP402", 402, "plan_required"],
  ["RP403", 403, "forbidden"], ["RP413", 413, "payload_too_large"],
] as const) {
  Deno.test(`actual uploadRPC preserves ${code} admission refusal`, async () => {
    const { response } = await refused(`${code}: Sign in or change this request`);
    assertEquals(response.status, status);
    assertEquals(await response.json(), { error: "Sign in or change this request", code: expected });
  });
}
Deno.test("actual uploadRPC monthly limit is deterministic quota, not burst retry", async () => {
  const { response } = await refused("RP429: monthly technical upload reservation ceiling exhausted");
  assertEquals(response.status, 429);
  assertEquals(await response.json(), {
    feature: "upload_bytes", error: "monthly technical upload reservation ceiling exhausted", code: "quota_exceeded",
  });
});
Deno.test("actual uploadRPC burst limit remains retryable rate limit", async () => {
  const { response } = await refused("RP429: Too many upload requests; try again later");
  assertEquals(response.status, 429);
  assertEquals(await response.json(), { error: "Too many upload requests; try again later", code: "rate_limited" });
});
Deno.test("actual uploadRPC database outage stays sanitized retryable upstream", async () => {
  const { response } = await refused("unexpected private database marker");
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "Durable upload state unavailable — retry", code: "upstream" });
});

async function compiledBoundary(source: string, message: string, status: number, code: string) {
  const start = source.indexOf("export async function uploadRPC("),
    end = source.indexOf("\nexport function row(", start);
  assertEquals(start >= 0 && end > start, true);
  const method = source.slice(start, end);
  const imports = `import {HttpError,respondError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};\n`;
  const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(imports + method)));
  const module = await import("data:application/typescript;base64," + encoded);
  try {
    await module.uploadRPC({ rpc: async () => ({ data: null, error: { message } }) }, "reserve_upload_assets", {});
    throw new Error("Admission must refuse");
  } catch (error) {
    const response = respondError(error);
    assertEquals(response.status, status, "Admission status must remain exact");
    assertEquals((await response.json()).code, code, "Admission code must preserve terminal versus burst policy");
  }
}
Deno.test("compiled removed RP401 mapping fails the same authorization boundary", async () => {
  const source = await Deno.readTextFile(new URL("./transport.ts", import.meta.url));
  await compiledBoundary(source, "RP401: Sign in to upload media", 401, "unauthorized");
  const mutated = source.replace("400|401|402", "400|402");
  assertEquals(mutated !== source, true);
  await assertRejects(() => compiledBoundary(mutated, "RP401: Sign in to upload media", 401, "unauthorized"), Error, "Admission status must remain exact");
});
Deno.test("compiled ignored monthly quota classification fails the same terminal boundary", async () => {
  const source = await Deno.readTextFile(new URL("./transport.ts", import.meta.url));
  await compiledBoundary(source, "RP429: monthly technical upload reservation ceiling exhausted", 429, "quota_exceeded");
  const mutated = source.replace('const monthlyCeiling = code === "429"', 'const monthlyCeiling = false && code === "429"');
  assertEquals(mutated !== source, true);
  await assertRejects(() => compiledBoundary(mutated, "RP429: monthly technical upload reservation ceiling exhausted", 429, "quota_exceeded"), Error, "Admission code must preserve terminal versus burst policy");
});
