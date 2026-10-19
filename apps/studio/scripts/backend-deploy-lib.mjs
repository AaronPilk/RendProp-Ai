import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import path from "node:path";
import ts from "typescript-parser";

export const PROJECT_REF = "ymgqpbnjpztwjsyvceld";
const FUNCTION_NAME = /^[a-z][a-z0-9-]{0,62}$/;
export const MODERN_SERVICE_FUNCTIONS = ["notify", "presenter-drain", "me", "uploads", "tours"];
// Only reviewed first-deployment candidates; no JWT weakening is permitted.
export const NEW_FUNCTION_POLICIES = Object.freeze({"property-sites":true,"property-video-plan":true,"property-video-jobs":true,"property-video-worker":false,"photo-quality-worker":false,"photo-quality-review":true,"ai-photo-v2":true,"photo-feedback":true});
export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function parseDeploymentArgs(args) {
  let functions, createNew, run = false, modernServiceTransport = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--run" && !run) run = true;
    else if (args[i] === "--modern-service-transport" && !modernServiceTransport) modernServiceTransport = true;
    else if (args[i] === "--create-new" && createNew === undefined) createNew = args[++i]?.split(",");
    else if (args[i] === "--functions" && functions === undefined) functions = args[++i]?.split(",");
    else throw new Error("Use --functions name[,other] and optional --run. No implicit all-functions deploy is allowed.");
  }
  assert(functions?.length && functions.every((name) => FUNCTION_NAME.test(name)), "Explicit valid --functions name[,other] is required.");
  assert(new Set(functions).size === functions.length, "Duplicate function selection.");
  if (modernServiceTransport) assert(MODERN_SERVICE_FUNCTIONS.every((name) => functions.includes(name)), "Modern transport transition requires all five declared service entrypoints.");
  if(createNew!==undefined){
    assert(createNew.length && new Set(createNew).size===createNew.length && createNew.every(name=>Object.hasOwn(NEW_FUNCTION_POLICIES,name)&&functions.includes(name)),"--create-new requires explicitly selected, declared new functions only.");
  }
  assert(!args.includes("--create-new")||createNew!==undefined,"--create-new requires explicit names.");
  return { functions, run, ...(createNew!==undefined?{createNew}:{}), ...(modernServiceTransport ? { modernServiceTransport: true } : {}) };
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

/** First deployment requires an explicit reviewed-name list. Existing entries
 * retain exact active/import-map/JWT checks, including partial-deploy retries.
 * Final readback still uses verifyLivePolicy with no missing exception. */
export function verifyDeploymentBefore(inventory,policy,createNew=[],modernServiceTransport=false){
  assert(Array.isArray(inventory),"Supabase function inventory must be a JSON array.");
  assert(Array.isArray(createNew)&&new Set(createNew).size===createNew.length&&createNew.every(name=>Object.hasOwn(NEW_FUNCTION_POLICIES,name)&&Object.hasOwn(policy,name)),"Only explicitly selected declared new functions may be created.");
  for(const name of createNew)assert.equal(policy[name],NEW_FUNCTION_POLICIES[name],`New function ${name} must preserve its reviewed JWT policy.`);
  const existing={},missing={};
  for(const[name,expected]of Object.entries(policy)){
    const matches=inventory.filter(row=>row.slug===name||row.name===name);
    if(matches.length===0&&createNew.includes(name))missing[name]={create:true,verifyJwt:expected};
    else existing[name]=expected;
  }
  const verified=modernServiceTransport?verifyModernServiceTransition(inventory,existing):verifyLivePolicy(inventory,existing);
  return {...verified,...missing};
}

/** Explicit transition only. Ordinary deploys keep the exact drift check. The
 * new application guards, never a JWT claim, authenticate these server routes.
 * No other function may lose its declared JWT policy through this option. */
export function verifyModernServiceTransition(inventory, policy) {
  assert(MODERN_SERVICE_FUNCTIONS.every((name) => Object.hasOwn(policy, name) && policy[name] === false), "Exactly five declared modern service policies must be false.");
  const previous = { ...policy };
  for (const name of MODERN_SERVICE_FUNCTIONS) {
    const rows = inventory.filter((row) => row.slug === name || row.name === name);
    assert(rows.length === 1 && typeof rows[0].verify_jwt === "boolean", "A unique boolean service policy is required.");
    previous[name] = rows[0].verify_jwt;
  }
  return verifyLivePolicy(inventory, previous);
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

// `supabase functions deploy --use-api` does not upload the AST closure above. Supabase CLI
// 2.101.0 uploads config static_files, then the entrypoint, then whatever this regex finds in
// raw text, recursively (apps/cli-go/pkg/function/deno.go importPathPattern + WalkImportPaths,
// pkg/function/deploy.go writeForm). The regex needs whitespace after import/export, so
// `import{x}from'./y.ts'` is invisible to it and the server bundle fails (HTTP 400, 17 Oct).
// Mirrored exactly: RE2's \s is [\t\n\f\r ] and its . excludes only \n.
export const SUPABASE_CLI_VERSION = "2.101.0";
const CLI_SPACE = "[\\t\\n\\f\\r ]";
export const CLI_IMPORT_PATTERN = new RegExp(`(?:import|export)${CLI_SPACE}+(?:type${CLI_SPACE}+)?(?:\\{[^{}]+\\}|[^\\n]*?)${CLI_SPACE}*(?:from)?${CLI_SPACE}*['"]([^\\n]*?)['"]|import\\(${CLI_SPACE}*['"]([^\\n]*?)['"]\\)`, "gi");
const goExt = (value) => { for (let i = value.length - 1; i >= 0 && value[i] !== "/"; i--) if (value[i] === ".") return value.slice(i); return ""; };

/** The CLI's own upload walk from one entrypoint, in workdir-relative paths and upload order.
 * `exists(p)` is "file" | "dir" | undefined. Throws where the CLI itself would abort. */
export function cliWalkUploads(entrypoint, exists, read) {
  const seen = new Set(), uploads = [], stack = [entrypoint];
  while (stack.length) {
    const current = stack.pop();
    if (seen.has(current)) continue;
    seen.add(current);
    // io/fs.ValidPath: no absolute paths and no "." or ".." elements after path.Clean.
    assert(!current.startsWith("/") && current !== "." && !current.split("/").includes(".."), `Supabase CLI ${SUPABASE_CLI_VERSION} would abort reading ${current}.`);
    const kind = exists(current);
    if (kind === "dir") throw new Error(`Supabase CLI ${SUPABASE_CLI_VERSION} would abort: ${current} is a directory.`);
    if (kind !== "file") {
      const parts = current.split("/");
      for (let i = 1; i < parts.length; i++) assert.notEqual(exists(parts.slice(0, i).join("/")), "file", `Supabase CLI ${SUPABASE_CLI_VERSION} would abort reading ${current}.`);
      continue; // the CLI warns and skips a missing file
    }
    uploads.push(current);
    for (const match of read(current).toString("utf8").matchAll(CLI_IMPORT_PATTERN)) {
      let mod = (match[1] || match[2] || "").trim();
      if (goExt(mod) === "") continue;
      const relative = mod.startsWith("./") || mod.startsWith("../");
      if (!relative && !mod.startsWith("/")) continue;
      if (relative) mod = path.posix.join(path.posix.dirname(current), mod);
      stack.push(path.posix.normalize(mod));
    }
  }
  return uploads;
}

/** Name every staged source the CLI's walk would miss, so the CLI uploads it as a static file.
 * Upload = static files + walked files: each source exactly once, nothing outside the function's
 * closure. Refuses instead of deploying if the walk would reach any other file. */
export function cliUploadPlan(closure, functions) {
  const files = new Map([...closure.files].map(([name, bytes]) => [`supabase/functions/${name}`, bytes]));
  for (const root of ["supabase/config.toml", "function-jwt-policy.json", "deployment-receipt.json"]) files.set(root, undefined);
  const dirs = new Set();
  for (const name of files.keys()) for (let dir = path.posix.dirname(name); dir !== "."; dir = path.posix.dirname(dir)) dirs.add(dir);
  const exists = (name) => files.has(name) ? "file" : dirs.has(name) ? "dir" : undefined;
  const read = (name) => { const bytes = files.get(name); assert(bytes, `Supabase CLI would upload staging metadata ${name}.`); return bytes; };
  const plan = {};
  for (const name of functions) {
    const expected = closure.sourcesByFunction[name].map((file) => `supabase/functions/${file}`);
    const walked = cliWalkUploads(`supabase/functions/${name}/index.ts`, exists, read);
    const outside = walked.filter((file) => !expected.includes(file));
    assert.deepEqual(outside, [], `Supabase CLI would upload files outside ${name}'s source closure.`);
    const staticFiles = expected.filter((file) => !walked.includes(file)).sort();
    for (const file of staticFiles) assert(/^supabase\/functions\/[A-Za-z0-9_][A-Za-z0-9._\/-]*$/.test(file), `Static upload path needs review: ${file}.`);
    plan[name] = { walked, static: staticFiles };
  }
  return plan;
}

/** static_files of one function in a staged config.toml, as the CLI resolves them (supabase/ + entry). */
export function stagedStaticFiles(config, name) {
  const section = config.split(/^\[functions\./m).find((part) => part.startsWith(`${name}]\n`));
  assert(section, `Staged config has no [functions.${name}] section.`);
  const line = section.split("\n").find((entry) => entry.startsWith("static_files = "));
  if (!line) return [];
  const files = JSON.parse(line.slice("static_files = ".length));
  assert(Array.isArray(files) && files.every((file) => typeof file === "string"), `Unreadable static_files for ${name}.`);
  return files.map((file) => path.posix.join("supabase", file));
}

/** Last check before `functions deploy`: from the staged files and config on disk, what the CLI
 * will upload must be this function's whole source closure, each file once. Throws otherwise. */
export function verifyCliUploadPlan(stage, manifest, name) {
  const exists = (file) => { try { const info = lstatSync(path.join(stage, file)); return info.isFile() ? "file" : info.isDirectory() ? "dir" : "other"; } catch (error) { if (error.code === "ENOENT" || error.code === "ENOTDIR") return undefined; throw error; } };
  const statics = stagedStaticFiles(readFileSync(path.join(stage, "supabase/config.toml"), "utf8"), name);
  const absent = statics.filter((file) => exists(file) !== "file");
  assert.deepEqual(absent, [], `Required static uploads are absent from the stage for ${name}; nothing was deployed.`);
  const upload = [...new Set(statics), ...cliWalkUploads(`supabase/functions/${name}/index.ts`, exists, (file) => readFileSync(path.join(stage, file)))];
  const expected = manifest.sourcesByFunction[name].map((file) => `supabase/functions/${file}`);
  const twice = upload.filter((file, index) => upload.indexOf(file) !== index);
  const missing = expected.filter((file) => !upload.includes(file)), outside = upload.filter((file) => !expected.includes(file));
  assert(!twice.length && !missing.length && !outside.length,
    `Supabase CLI ${SUPABASE_CLI_VERSION} would not upload exactly ${name}'s sources (missing ${missing.length}: ${missing.slice(0, 3).join(", ")}; outside ${outside.length}; twice ${twice.length}). Nothing was deployed.`);
  return { uploadFiles: upload.length, staticFiles: statics.length, walkedFiles: upload.length - statics.length };
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
  const cliUpload = cliUploadPlan(closure, Object.keys(policy).filter((name) => closure.sourcesByFunction[name]));
  const statics = (name) => cliUpload[name]?.static.length ? `static_files = [${cliUpload[name].static.map((file) => JSON.stringify(`./${file.slice("supabase/".length)}`)).join(", ")}]\n` : "";
  const config = `project_id = "${PROJECT_REF}"\n\n` + Object.entries(policy).map(([name, value]) => `[functions.${name}]\nverify_jwt = ${value}\nentrypoint = "./functions/${name}/index.ts"\n${statics(name)}`).join("\n");
  await writeFile(path.join(stage, "supabase/config.toml"), config, { flag: "wx" });
  await writeFile(path.join(stage, "function-jwt-policy.json"), JSON.stringify(policy, null, 2) + "\n", { flag: "wx" });
  return { hashes, configSha256: sha256(config), policySha256: sha256(JSON.stringify(policy)), runtimeByFunction: closure.runtimeByFunction, sourcesByFunction: closure.sourcesByFunction, externalImports: closure.externalImports, cliUpload: { version: SUPABASE_CLI_VERSION, byFunction: cliUpload } };
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
  // A source uploaded as a static file may also come back under a server-specific prefix.
  // Such an extra file passes only as an exact byte copy of one of this function's planned
  // static sources; anything else is unexpected deployed code.
  const statics = (manifest.cliUpload?.byFunction?.[name]?.static ?? []).map((file) => file.slice("supabase/functions/".length));
  const staticCopies = [];
  for (const file of present) {
    const hash = sha256(await readFile(path.join(root, file)));
    if (manifest.sourcesByFunction[name].includes(file)) {
      assert.equal(hash, manifest.hashes[file], `Deployed source mismatch ${name}: ${file}.`);
      continue;
    }
    const of = statics.find((source) => file.endsWith(`/${source}`) && hash === manifest.hashes[source]);
    assert(of, `Unexpected deployed source ${name}: ${file}.`);
    staticCopies.push({ file, of });
  }
  return { matchedSourceFiles: present.length - staticCopies.length, runtimeSourceFiles: expected.length, stagedTypeOnlyNotInRuntime: manifest.sourcesByFunction[name].filter((file) => !present.includes(file) && !expected.includes(file)), ...(staticCopies.length ? { staticCopies } : {}) };
}
