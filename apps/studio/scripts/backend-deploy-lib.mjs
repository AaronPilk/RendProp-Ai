import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import path from "node:path";
import ts from "typescript-parser";

export const PROJECT_REF = "ymgqpbnjpztwjsyvceld";
const FUNCTION_NAME = /^[a-z][a-z0-9-]{0,62}$/;
export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function parseDeploymentArgs(args) {
  let functions, run = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--run" && !run) run = true;
    else if (args[i] === "--functions" && functions === undefined) functions = args[++i]?.split(",");
    else throw new Error("Use --functions name[,other] and optional --run. No implicit all-functions deploy is allowed.");
  }
  assert(functions?.length && functions.every((name) => FUNCTION_NAME.test(name)), "Explicit valid --functions name[,other] is required.");
  assert(new Set(functions).size === functions.length, "Duplicate function selection.");
  return { functions, run };
}

export function selectedPolicy(policy, functions) {
  assert(policy && typeof policy === "object" && !Array.isArray(policy), "Invalid JWT policy file.");
  for (const [name, value] of Object.entries(policy)) {
    assert(FUNCTION_NAME.test(name) && typeof value === "boolean", "JWT policy must map function names to booleans.");
  }
  return Object.fromEntries(functions.map((name) => {
    assert(Object.hasOwn(policy, name), `No declared JWT policy for ${name}.`);
    return [name, policy[name]];
  }));
}

export function verifyLivePolicy(inventory, policy) {
  assert(Array.isArray(inventory), "Supabase function inventory must be a JSON array.");
  return Object.fromEntries(Object.entries(policy).map(([name, expected]) => {
    const matches = inventory.filter((row) => row.slug === name || row.name === name);
    assert.equal(matches.length, 1, `Expected exactly one live function named ${name}; no automatic new-function deployment.`);
    const live = matches[0];
    assert.equal(live.verify_jwt, expected, `Live JWT policy drift for ${name}; review the policy before deploying.`);
    assert.equal(live.import_map, false, `Live import map for ${name} needs explicit deployment support.`);
    assert.equal(live.status, "ACTIVE", `Live function ${name} is not ACTIVE.`);
    return [name, { id: live.id, version: live.version, verifyJwt: expected }];
  }));
}

/** Parse syntax, never comments/strings that happen to resemble imports. */
export function sourceImports(source, filename) {
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true);
  assert.equal(ast.parseDiagnostics.length, 0, `Cannot parse TypeScript source ${filename}.`);
  const imports = [];
  const add = (node, runtime) => {
    assert(node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)), `Computed import in ${filename}; use a literal module specifier.`);
    imports.push({ specifier: node.text, runtime });
  };
  const visit = (node) => {
    if (ts.isImportDeclaration(node)) {
      const clause = node.importClause;
      const bindings = clause?.namedBindings;
      const runtime = !clause || (!clause.isTypeOnly && (!!clause.name || !bindings || ts.isNamespaceImport(bindings) || bindings.elements.length === 0 || bindings.elements.some((item) => !item.isTypeOnly)));
      add(node.moduleSpecifier, runtime);
    } else if (ts.isExportDeclaration(node) && node.moduleSpecifier) {
      const clause = node.exportClause;
      add(node.moduleSpecifier, !node.isTypeOnly && (!clause || !ts.isNamedExports(clause) || clause.elements.length === 0 || clause.elements.some((item) => !item.isTypeOnly)));
    } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
      add(node.moduleReference.expression, !node.isTypeOnly);
    } else if (ts.isImportTypeNode(node)) {
      assert(ts.isLiteralTypeNode(node.argument), `Computed type import in ${filename}.`);
      add(node.argument.literal, false);
    } else if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword || (ts.isIdentifier(node.expression) && node.expression.text === "require"))) {
      add(node.arguments[0], true);
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  for (const reference of ast.referencedFiles) imports.push({ specifier: reference.fileName.startsWith(".") ? reference.fileName : `./${reference.fileName}`, runtime: false });
  assert.equal(ast.typeReferenceDirectives.length, 0, `Triple-slash package type references need explicit support: ${filename}.`);
  return imports;
}

function inside(root, file) {
  const rel = path.relative(root, file);
  return rel !== "" && !rel.startsWith(`..${path.sep}`) && rel !== ".." && !path.isAbsolute(rel);
}

async function assertNoImplicitConfig(root, functionNames) {
  // No such files are currently used. Fail closed if introduced, rather than
  // silently deploying without their import-map/compiler semantics.
  for (const dir of [root, ...functionNames.map((name) => path.join(root, name))]) {
    for (const name of ["deno.json", "deno.jsonc", "import_map.json", "import-map.json", "package.json"]) {
      const found = await lstat(path.join(dir, name)).then(() => true, (e) => { if (e.code === "ENOENT") return false; throw e; });
      assert(!found, `Unsupported implicit dependency config ${path.join(dir, name)}; add explicit staging/resolution support first.`);
    }
  }
}

export async function sourceClosure(functionsRoot, functions) {
  const root = await realpath(functionsRoot);
  const files = new Map(), graphs = new Map(), external = new Set();
  async function collect(file) {
    assert(inside(root, file), `Import path escapes functions root: ${file}.`);
    const canonical = await realpath(file);
    assert(inside(root, canonical), `Symlink import escapes functions root: ${file}.`);
    assert.equal(canonical, file, `Symlink source is not allowed: ${file}.`);
    if (files.has(file)) return;
    assert((await lstat(file)).isFile(), `Imported source is not a file: ${file}.`);
    assert(/\.(?:[cm]?[jt]sx?|json)$/.test(file), `Unsupported import extension: ${file}.`);
    const bytes = await readFile(file);
    files.set(file, bytes);
    const dependencies = [];
    graphs.set(file, dependencies);
    if (file.endsWith(".json")) { JSON.parse(bytes.toString("utf8")); return; }
    for (const item of sourceImports(bytes.toString("utf8"), path.relative(root, file))) {
      const s = item.specifier;
      if (/^(?:https:|npm:|jsr:|node:)/.test(s)) {
        if (s.startsWith("https:")) {
          const url = new URL(s);
          assert(!url.username && !url.password, "Credentials in external import URL are forbidden.");
        }
        external.add(s);
        continue;
      }
      assert(s.startsWith("./") || s.startsWith("../"), `Unsupported bare/absolute import in ${file}: ${s}.`);
      assert(!/[\\?#%\0]/.test(s), `Ambiguous local import in ${file}: ${s}.`);
      const child = path.resolve(path.dirname(file), s);
      dependencies.push({ file: child, runtime: item.runtime });
      await collect(child);
    }
  }
  for (const name of functions) {
    assert(FUNCTION_NAME.test(name), "Invalid function name.");
    await collect(path.join(root, name, "index.ts"));
  }
  await assertNoImplicitConfig(root, [...new Set([...files.keys()].map((file) => path.relative(root, file).split(path.sep)[0]))]);
  const relative = (file) => path.relative(root, file).split(path.sep).join("/");
  const runtimeByFunction = {}, sourcesByFunction = {};
  for (const name of functions) {
    const reached = new Set();
    const walk = (file) => {
      if (reached.has(file)) return;
      reached.add(file);
      for (const dependency of graphs.get(file) ?? []) if (dependency.runtime) walk(dependency.file);
    };
    walk(path.join(root, name, "index.ts"));
    runtimeByFunction[name] = [...reached].map(relative).sort();
    const all = new Set();
    const walkAll = (file) => { if (all.has(file)) return; all.add(file); for (const dependency of graphs.get(file) ?? []) walkAll(dependency.file); };
    walkAll(path.join(root, name, "index.ts"));
    sourcesByFunction[name] = [...all].map(relative).sort();
  }
  return {
    files: new Map([...files].map(([file, bytes]) => [relative(file), bytes]).sort(([a], [b]) => a.localeCompare(b))),
    runtimeByFunction,
    sourcesByFunction,
    externalImports: [...external].sort(),
  };
}

export async function stageDeployment(stage, closure, policy) {
  const root = path.join(stage, "supabase/functions");
  const hashes = {};
  for (const [name, bytes] of closure.files) {
    const file = path.join(root, name);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, bytes, { flag: "wx" });
    hashes[name] = sha256(bytes);
  }
  const config = `project_id = "${PROJECT_REF}"\n\n` + Object.entries(policy).map(([name, value]) => `[functions.${name}]\nverify_jwt = ${value}\nentrypoint = "./functions/${name}/index.ts"\n`).join("\n");
  await writeFile(path.join(stage, "supabase/config.toml"), config, { flag: "wx" });
  await writeFile(path.join(stage, "function-jwt-policy.json"), JSON.stringify(policy, null, 2) + "\n", { flag: "wx" });
  return { hashes, configSha256: sha256(config), policySha256: sha256(JSON.stringify(policy)), runtimeByFunction: closure.runtimeByFunction, sourcesByFunction: closure.sourcesByFunction, externalImports: closure.externalImports };
}

export async function verifyStagedSnapshot(stage, manifest) {
  assert.equal(sha256(await readFile(path.join(stage, "supabase/config.toml"))), manifest.configSha256, "Staged function config changed.");
  const policy = JSON.parse(await readFile(path.join(stage, "function-jwt-policy.json"), "utf8"));
  assert.equal(sha256(JSON.stringify(policy)), manifest.policySha256, "Staged JWT policy changed.");
  const stagedFiles = [];
  async function walk(dir) { for (const item of await readdir(dir, { withFileTypes: true })) { assert(!item.isSymbolicLink(), "Unexpected staged symlink."); const file = path.join(dir, item.name); if (item.isDirectory()) await walk(file); else stagedFiles.push(path.relative(path.join(stage, "supabase/functions"), file).split(path.sep).join("/")); } }
  await walk(path.join(stage, "supabase/functions"));
  assert.deepEqual(stagedFiles.sort(), Object.keys(manifest.hashes).sort(), "Staged source closure changed.");
  for (const [name, hash] of Object.entries(manifest.hashes)) assert.equal(sha256(await readFile(path.join(stage, "supabase/functions", name))), hash, `Staged source changed: ${name}.`);
}

export async function verifyDownloadedSources(downloadDir, name, manifest) {
  const root = path.join(downloadDir, "supabase/functions");
  const present = [];
  async function walk(dir) {
    for (const item of await readdir(dir, { withFileTypes: true })) {
      assert(!item.isSymbolicLink(), "Unexpected symlink in downloaded function.");
      const file = path.join(dir, item.name);
      if (item.isDirectory()) await walk(file);
      else present.push(path.relative(root, file).split(path.sep).join("/"));
    }
  }
  await walk(root);
  const expected = manifest.runtimeByFunction[name];
  assert(expected, `No runtime manifest for ${name}.`);
  // Type-only modules may be retained by future bundlers. Permit them only when
  // they were explicitly staged; every runtime module must be present.
  for (const file of expected) assert(present.includes(file), `Readback omitted runtime source ${name}: ${file}.`);
  for (const file of present) {
    assert(manifest.sourcesByFunction[name].includes(file), `Unexpected deployed source ${name}: ${file}.`);
    assert.equal(sha256(await readFile(path.join(root, file))), manifest.hashes[file], `Deployed source mismatch ${name}: ${file}.`);
  }
  return { matchedSourceFiles: present.length, runtimeSourceFiles: expected.length, stagedTypeOnlyNotInRuntime: manifest.sourcesByFunction[name].filter((file) => !present.includes(file) && !expected.includes(file)) };
}
