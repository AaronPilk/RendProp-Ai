import { check } from "./common.ts";
import { compileStyle } from "./compile.ts";
import {
  bindAssets,
  blindAssignments,
  expectedAssets,
  preregister,
  scoreExperiment,
} from "./experiment.ts";
import { CATALOG, catalogRefs } from "./policy.ts";

async function readJSON(path: string): Promise<unknown> {
  // Bounded even if the file grows after stat; don't read credentials via links.
  const info = await Deno.lstat(path);
  check(
    info.isFile && !info.isSymlink && info.size <= 1_048_576,
    "input must be a regular JSON file at most 1 MiB",
  );
  const file = await Deno.open(path, { read: true });
  try {
    const bytes = new Uint8Array(1_048_577);
    let used = 0;
    while (used < bytes.length) {
      const n = await file.read(bytes.subarray(used));
      if (n === null) break;
      used += n;
    }
    check(used <= 1_048_576, "input byte limit");
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, used)),
    );
  } finally {
    file.close();
  }
}
export async function main(args: string[]): Promise<void> {
  const [command, ...paths] = args;
  const counts: Record<string, number> = {
    catalog: 0,
    compile: 2,
    register: 1,
    bind: 2,
    assign: 1,
    "asset-plan": 1,
    score: 2,
  };
  check(
    Object.hasOwn(counts, command) && paths.length === counts[command],
    "usage: catalog | compile STYLE_REF EDL | register INPUT | asset-plan REGISTRATION | bind REGISTRATION ASSETS | assign BOUND | score BOUND SCORES",
  );
  const values = await Promise.all(paths.map(readJSON));
  let output: unknown;
  switch (command) {
    case "catalog":
      output = {
        stage: "offline-only",
        policies: CATALOG,
        refs: await catalogRefs(),
      };
      break;
    case "compile":
      output = await compileStyle(values[0], values[1]);
      break;
    case "register":
      output = await preregister(values[0]);
      break;
    case "assign":
      output = await blindAssignments(values[0]);
      break;
    case "bind":
      output = await bindAssets(values[0], values[1]);
      break;
    case "asset-plan":
      output = {
        private_operator_only: true,
        assets: await expectedAssets(values[0]),
      };
      break;
    case "score":
      output = await scoreExperiment(values[0], values[1]);
      break;
  }
  console.log(JSON.stringify(output, null, 2));
}
if (import.meta.main) {
  try {
    await main(Deno.args);
  } catch (error) {
    console.error(
      `FAIL: ${error instanceof Error ? error.message : "invalid input"}`,
    );
    Deno.exit(1);
  }
}
