import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
// @ts-ignore Release helpers are plain ESM, executed without tsx in production.
import { SUPABASE_CLI_VERSION, verifyCliUploadPlan } from "../scripts/backend-deploy-lib.mjs";

// Regression for 17 Oct 21:44Z: property-video-jobs reached Supabase as index.ts alone and the
// bundle failed (HTTP 400, _shared/cors.ts not found). The packager under test stages the real V1
// pair; the check then reads that stage's files and config.toml from disk and walks them the way
// Supabase CLI 2.101.0 does. RENDPROP_PACKAGER_LIB=<path to another backend-deploy-lib.mjs> stages
// with that packager instead, e.g. 01a89e85's, which fails here exactly as production did.
const packagerPath = process.env.RENDPROP_PACKAGER_LIB
  ? path.resolve(process.env.RENDPROP_PACKAGER_LIB)
  : path.resolve(import.meta.dirname, "../scripts/backend-deploy-lib.mjs");

test("the staged V1 deploy makes Supabase CLI 2.101.0 upload every source of jobs and plan, once each", async () => {
  const packager = await import(pathToFileURL(packagerPath).href);
  const repo = path.resolve(import.meta.dirname, "../../..");
  const functions = ["property-video-jobs", "property-video-plan"];
  const policy = packager.selectedPolicy(JSON.parse(await readFile(path.join(repo, "services/supabase/function-jwt-policy.json"), "utf8")), functions);
  const closure = await packager.sourceClosure(path.join(repo, "services/supabase/functions"), functions);
  const root = await mkdtemp(path.join(tmpdir(), "rendprop-upload-coverage-"));
  try {
    const stage = path.join(root, "stage"), manifest = await packager.stageDeployment(stage, closure, policy);
    assert.equal(SUPABASE_CLI_VERSION, "2.101.0");
    for (const name of functions) {
      const upload = verifyCliUploadPlan(stage, manifest, name);
      assert.equal(upload.uploadFiles, closure.sourcesByFunction[name].length, `${name}: the whole source closure is uploaded`);
    }
    assert(verifyCliUploadPlan(stage, manifest, "property-video-jobs").staticFiles > 0, "jobs needs static uploads for its compact imports");
    assert(closure.sourcesByFunction["property-video-jobs"].includes("_shared/cors.ts"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
