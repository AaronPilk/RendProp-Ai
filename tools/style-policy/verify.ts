// Runs only existing Deno against owned local fixtures; no service SDK or shell.
import { check } from "./common.ts";
import {
  agentFixture,
  equal,
  experimentFixture,
  registrationFixture,
} from "./test_helpers.ts";
import { catalogRefs } from "./policy.ts";

const source = new URL("./", import.meta.url);
const files = [
  "common.ts",
  "policy.ts",
  "compile.ts",
  "experiment.ts",
  "test_helpers.ts",
  "policy_test.ts",
  "compile_test.ts",
  "experiment_test.ts",
];
const tests = ["policy_test.ts", "compile_test.ts", "experiment_test.ts"];
const EXPECTED_TESTS = 101;
async function run(args: string[], log: string) {
  const output = await new Deno.Command(Deno.execPath(), {
    args,
    clearEnv: true,
    env: { NO_COLOR: "1", DENO_NO_PROMPT: "1" },
    stdout: "piped",
    stderr: "piped",
  }).output();
  const stdout = new TextDecoder().decode(output.stdout),
    stderr = new TextDecoder().decode(output.stderr);
  await Deno.writeTextFile(log, `exit=${output.code}\n${stdout}\n${stderr}`);
  return { code: output.code, stdout, stderr };
}
const runtime = [
  "--no-config",
  "--no-lock",
  "--cached-only",
  "--deny-net",
  "--deny-env",
  "--deny-run",
];
function testSummary(
  result: { code: number; stdout: string; stderr: string },
  expected: number,
): void {
  check(
    result.code === 0 &&
      new RegExp(`ok \\| ${expected} passed \\| 0 failed`).test(
        result.stdout,
      ) && !/ignored/.test(result.stdout),
    "positive suite failed or test count changed",
  );
}
async function verify() {
  const out = await Deno.makeTempDir({
    dir: "/tmp",
    prefix: "rendprop-style-policy-verify-",
  });
  const cli = new URL("cli.ts", source).pathname;
  // URL.pathname is escaped for this workspace's space; Deno accepts file URLs.
  const cliURL = new URL("cli.ts", source).href;
  check(cli.endsWith("cli.ts"), "unexpected CLI target");
  const invalid = new URL("fixtures/invalid-registration.json", source);
  const negative = await run([
    "run",
    ...runtime,
    "--allow-read",
    cliURL,
    "register",
    decodeURIComponent(invalid.pathname),
  ], `${out}/negative-cli.log`);
  check(
    negative.code === 1 &&
      negative.stderr.includes("FAIL: unexpected or missing keys"),
    "known-invalid CLI did not fail correctly",
  );

  const baseline = await run([
    "test",
    ...runtime,
    ...tests.map((f) => new URL(f, source).href),
  ], `${out}/unit-tests.log`);
  testSummary(baseline, EXPECTED_TESTS);

  const fixture = await experimentFixture();
  const inputPath = `${out}/registration-input.json`,
    sealedPath = `${out}/registration.json`,
    scoresPath = `${out}/synthetic-scores.json`;
  await Deno.writeTextFile(
    inputPath,
    JSON.stringify(await registrationFixture()),
  );
  const registration = await run([
    "run",
    ...runtime,
    `--allow-read=${out}`,
    cliURL,
    "register",
    inputPath,
  ], `${out}/register-cli.log`);
  check(registration.code === 0, "register CLI failed");
  equal(JSON.parse(registration.stdout), fixture.seal);
  await Deno.writeTextFile(sealedPath, registration.stdout);
  const assetsPath = `${out}/output-declarations.json`,
    boundPath = `${out}/bound-experiment.json`;
  await Deno.writeTextFile(assetsPath, JSON.stringify(fixture.input.assets));
  const binding = await run([
    "run",
    ...runtime,
    `--allow-read=${out}`,
    cliURL,
    "bind",
    sealedPath,
    assetsPath,
  ], `${out}/bind-cli.log`);
  check(binding.code === 0, "bind CLI failed");
  equal(JSON.parse(binding.stdout), fixture.bound);
  await Deno.writeTextFile(boundPath, binding.stdout);
  const assignment = await run([
    "run",
    ...runtime,
    `--allow-read=${out}`,
    cliURL,
    "assign",
    boundPath,
  ], `${out}/assign-cli.log`);
  check(assignment.code === 0, "assign CLI failed");
  equal(JSON.parse(assignment.stdout).assignments.length, 72);
  await Deno.writeTextFile(scoresPath, JSON.stringify(fixture.input));
  const scored = await run([
    "run",
    ...runtime,
    `--allow-read=${out}`,
    cliURL,
    "score",
    boundPath,
    scoresPath,
  ], `${out}/score-cli.log`);
  check(scored.code === 0, "score CLI failed");
  const summary = JSON.parse(scored.stdout);
  equal(summary.judgments, 72);
  equal(summary.quality_win_claimed, false);
  equal(summary.publication_ready, false);
  const edlPath = `${out}/edl.json`, refPath = `${out}/ref.json`;
  await Deno.writeTextFile(edlPath, JSON.stringify(agentFixture()));
  await Deno.writeTextFile(refPath, JSON.stringify((await catalogRefs())[0]));
  const compiled = await run([
    "run",
    ...runtime,
    `--allow-read=${out}`,
    cliURL,
    "compile",
    refPath,
    edlPath,
  ], `${out}/compile-cli.log`);
  check(compiled.code === 0, "compile CLI failed");
  equal(JSON.parse(compiled.stdout).edl, agentFixture());

  const mutants = [
    {
      name: "leak-side-through-order",
      file: "experiment.ts",
      needle: "perRater.sort(",
      replacement: "perRater.slice().sort(",
      count: 1,
    },
    {
      name: "accept-substituted-output",
      file: "experiment.ts",
      needle: "canonical(input.assets) === canonical(bound.assets)",
      replacement: "true",
      count: 1,
    },
    {
      name: "ignore-style-hash",
      file: "policy.ts",
      needle: "await hash(policy) === ref.sha256",
      replacement: "true",
      count: 1,
    },
    {
      name: "alter-edl",
      file: "compile.ts",
      needle: "const edl = validateEDL(rawEDL);",
      replacement:
        'const edl = JSON.parse(JSON.stringify(validateEDL(rawEDL))); if (edl.mode === "recorded_agent" && edl.cutaways.length) edl.cutaways[0].start += 0.1;',
      count: 1,
    },
    {
      name: "false-room-safety",
      file: "compile.ts",
      needle: 'room_safety: "unverified"',
      replacement: 'room_safety: "verified"',
      count: 1,
    },
    {
      name: "false-quality-win",
      file: "experiment.ts",
      needle: "quality_win_claimed: false",
      replacement: "quality_win_claimed: true",
      count: 2,
    },
    {
      name: "accept-zero-score",
      file: "experiment.ts",
      needle: "number(metrics[metric], 1, 5, true)",
      replacement: "number(metrics[metric], 0, 5, true)",
      count: 1,
    },
  ];
  const mutationResults = [];
  for (const mutant of mutants) {
    const directory = `${out}/${mutant.name}`;
    await Deno.mkdir(directory);
    for (const file of files) {
      let content = await Deno.readTextFile(new URL(file, source));
      if (file === mutant.file) {
        check(
          content.split(mutant.needle).length - 1 === mutant.count,
          "mutation anchor drifted",
        );
        content = content.replaceAll(mutant.needle, mutant.replacement);
      }
      // Only copied test modules change; all upstream imports stay original/read-only.
      content = content.replaceAll(
        '"../../services/',
        `"${new URL("../../services/", source).href}`,
      );
      await Deno.writeTextFile(`${directory}/${file}`, content);
    }
    const result = await run([
      "test",
      ...runtime,
      ...tests.map((f) => `${directory}/${f}`),
    ], `${out}/${mutant.name}.log`);
    check(
      result.code === 1 &&
        /FAILED \| \d+ passed \| [1-9]\d* failed/.test(result.stdout) &&
        !/ignored/.test(result.stdout),
      `mutant survived or did not execute tests: ${mutant.name}`,
    );
    mutationResults.push({
      name: mutant.name,
      expected_failure_exit: result.code,
    });
  }
  const report = {
    source_base: "f14081d49d5fb40b1dde59562176692ddb2664c6",
    evidence_directory: out,
    tests: EXPECTED_TESTS,
    failures: 0,
    skips: 0,
    invalid_cli_exit: negative.code,
    mutation_results: mutationResults,
    synthetic_judgments: 72,
    quality_win_claimed: false,
    no_services_or_generation: true,
  };
  await Deno.writeTextFile(
    `${out}/summary.json`,
    JSON.stringify(report, null, 2),
  );
  console.log(JSON.stringify(report, null, 2));
}
if (import.meta.main) {
  try {
    await verify();
  } catch (error) {
    console.error(
      `FAIL: ${error instanceof Error ? error.message : "verification error"}`,
    );
    Deno.exit(1);
  }
}
