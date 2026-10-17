#!/usr/bin/env node
/** Offline by default. --run alone is never a selection. No credential files. */
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { PROJECT_REF, SUPABASE_CLI_VERSION, parseDeploymentArgs, selectedPolicy, sourceClosure, stageDeployment, verifyDownloadedSources, verifyLivePolicy, verifyDeploymentBefore, verifyStagedSnapshot } from "./backend-deploy-lib.mjs";

const HELP = "Usage: node scripts/deploy-backend.mjs --functions studio[,other] [--run] [--modern-service-transport] [--create-new property-sites[,property-video-plan,photo-quality-review,ai-photo-v2,photo-feedback]]\nWithout --run: stage and hash local source only; no network, no deployment.\nWith --run: use the Supabase CLI's existing login or SUPABASE_ACCESS_TOKEN; verify live JWT policy, deploy only selected functions, download and compare source hashes.\nThe staged config names every source the CLI's own upload walk would miss as a static file, so each function uploads its whole closure once; --run refuses any Supabase CLI other than the version that plan mirrors (2.101.0).\nThe explicit modern transport option permits only the five declared service entrypoints to move to application-level service authentication; all five must be selected. Other JWT policies and final readback remain exact.\nThe explicit --create-new list permits only reviewed new endpoints to be absent before deployment; their declared JWT policies remain exact, existing entries remain exact and all final source/policy readbacks are mandatory.\n";
if (process.argv.includes("--help")) { console.log(HELP); process.exit(0); }

async function cli(args) {
  return await new Promise((resolve, reject) => {
    const child = spawn("supabase", args, { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("Supabase CLI timed out; inspect live state before retrying.")); }, 180_000);
    child.stdout.on("data", (bytes) => { stdout += bytes; if (stdout.length > 4_000_000) child.kill("SIGTERM"); });
    child.stderr.on("data", (bytes) => { stderr += bytes; if (stderr.length > 4_000_000) child.kill("SIGTERM"); });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error(`Supabase ${args.slice(0, 3).join(" ")} failed (exit ${code}). ${stderr.slice(-2000)}`));
      else resolve(stdout);
    });
  });
}

let stage, receipt;
try {
  const options = parseDeploymentArgs(process.argv.slice(2));
  const repo = path.resolve(import.meta.dirname, "../../..");
  const policy = selectedPolicy(JSON.parse(await readFile(path.join(repo, "services/supabase/function-jwt-policy.json"), "utf8")), options.functions);
  const closure = await sourceClosure(path.join(repo, "services/supabase/functions"), options.functions);
  stage = await mkdtemp(path.join(tmpdir(), "rendprop-backend-stage-"));
  const manifest = await stageDeployment(stage, closure, policy);
  receipt = { schema: 1, createdAt: new Date().toISOString(), mode: options.run ? "run" : "dry-run", status: "staged", projectRef: PROJECT_REF, functions: options.functions, jwtPolicy: policy, modernServiceTransport: options.modernServiceTransport === true, requestedNewFunctions:options.createNew??[], manifest };
  const save = async () => writeFile(path.join(stage, "deployment-receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
  await save();
  if (options.run) {
    // The staged static_files plan mirrors this CLI version's upload walk; another version must be re-verified first.
    const versions = (await cli(["--version"])).split(/\r?\n/).map((line) => line.trim()).filter((line) => /^\d+\.\d+\.\d+$/.test(line));
    receipt.cliVersion = versions.join(",") || "unreadable";
    if (versions.length !== 1 || versions[0] !== SUPABASE_CLI_VERSION) throw new Error(`Supabase CLI ${receipt.cliVersion} is installed; the upload plan was verified for ${SUPABASE_CLI_VERSION}. Nothing was deployed.`);
    const inventory = JSON.parse(await cli(["functions", "list", "--project-ref", PROJECT_REF, "-o", "json", "--workdir", stage]));
    receipt.before = verifyDeploymentBefore(inventory,policy,options.createNew??[],options.modernServiceTransport===true);
    receipt.status = "deploying";
    receipt.completed = {};
    await save();
    for (const name of options.functions) {
      await verifyStagedSnapshot(stage, manifest);
      // One explicit name per invocation: mixed JWT rules come from staged TOML,
      // never a global --no-verify-jwt switch and never --prune.
      await cli(["functions", "deploy", name, "--project-ref", PROJECT_REF, "--use-api", "--workdir", stage]);
      receipt.completed[name] = { status: "deployed-awaiting-readback" };
      await save();
      const readback = await mkdtemp(path.join(tmpdir(), `rendprop-backend-readback-${name}-`));
      await mkdir(path.join(readback, "supabase"), { recursive: true });
      await cli(["functions", "download", name, "--use-api", "--project-ref", PROJECT_REF, "--workdir", readback]);
      receipt.completed[name] = { status: "source-verified", readback, ...await verifyDownloadedSources(readback, name, manifest) };
      await save();
    }
    receipt.after = verifyLivePolicy(JSON.parse(await cli(["functions", "list", "--project-ref", PROJECT_REF, "-o", "json", "--workdir", stage])), policy);
    receipt.status = "verified";
    await save();
  }
  console.log(JSON.stringify({ status: receipt.status, mode: receipt.mode, functions: options.functions, jwtPolicy: policy, stagedSourceFiles: closure.files.size, stage, receipt: path.join(stage, "deployment-receipt.json") }, null, 2));
} catch (error) {
  if (stage && receipt) {
    receipt.status = "failed";
    receipt.failure = error.message;
    await writeFile(path.join(stage, "deployment-receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
    console.error(`Receipt retained at ${path.join(stage, "deployment-receipt.json")}. Some selected functions may already have deployed; inspect the receipt before retrying.`);
  }
  console.error(error.message);
  process.exitCode = 1;
}
