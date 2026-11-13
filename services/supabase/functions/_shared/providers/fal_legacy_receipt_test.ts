import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { falLegacyReceipt, falLegacyReceiptMatchesModel } from "./fal.ts";

const base = "https://queue.fal.run/fal-ai/topaz/requests/synthetic-job";
const receipt = falLegacyReceipt(`${base}/status`, base)!;
Deno.test("legacy FAL root comes from the complete stored endpoint, never an arbitrary prefix", () => {
  assertEquals(receipt, {endpoint:"fal-ai/topaz",requestId:"synthetic-job"});
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz/upscale/video", "synthetic-job", receipt),true);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz-upscale/video", "synthetic-job", receipt),false);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/another-model/topaz", "synthetic-job", receipt),false);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz/upscale/video", "another-job", receipt),false);
  assertEquals(falLegacyReceiptMatchesModel(null, "synthetic-job", receipt),false);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz/../another", "synthetic-job", receipt),false);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz/upscale/video", "synthetic-job", {...receipt,endpoint:"fal-ai/topaz/upscale"}),false);
  assertEquals(falLegacyReceiptMatchesModel("fal-ai/topaz/upscale/video", "synthetic-job", {...receipt,endpoint:"fal-ai"}),false);
});
for (const [label, status, response] of [
  ["invalid URL", "invalid", base],
  ["HTTP", `${base}/status`.replace("https:","http:"), base],
  ["other host", `${base}/status`.replace("queue.fal.run","other.fal.run"), base.replace("queue.fal.run","other.fal.run")],
  ["suffix host", `${base}/status`.replace("queue.fal.run","queue.fal.run.invalid"), base],
  ["username", `${base}/status`.replace("https://","https://caller@"), base],
  ["password", `${base}/status`.replace("https://","https://caller:password@"), base],
  ["foreign response", `${base}/status`, base.replace("queue.fal.run","other.fal.run")],
  ["unapproved port", `${base}/status`.replace("queue.fal.run","queue.fal.run:8443"), base],
  ["status query", `${base}/status?token=synthetic`, base],
  ["result query", `${base}/status`, `${base}?token=synthetic`],
  ["fragment", `${base}/status#synthetic`, base],
  ["encoded namespace", `${base}/status`.replace("topaz","%74opaz"), base.replace("topaz","%74opaz")],
  ["encoded request", `${base}/status`.replace("synthetic-job","%2Fanother"), base.replace("synthetic-job","%2Fanother")],
  ["request mismatch", `${base}/status`, base.replace("synthetic-job","another-job")],
  ["endpoint mismatch", `${base}/status`, base.replace("topaz","veo3.1")],
  ["response status path", `${base}/status`, `${base}/status`],
  ["extra result path", `${base}/status`, `${base}/response`],
  ["extra status path", `${base}/status/stream`, base],
] as const) {
  Deno.test(`legacy FAL paired URLs reject ${label}`,()=>assertEquals(falLegacyReceipt(status,response),null));
}
