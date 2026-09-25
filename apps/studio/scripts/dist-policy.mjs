import assert from "node:assert/strict";
import { parseEnv } from "node:util";
import ts from "typescript-parser";

const PUBLIC_NAMES = ["VITE_SUPABASE_URL", "VITE_SUPABASE_PUBLISHABLE_KEY"];
export function connectedProductionConfig(fileText = "", env = {}) {
  const file = parseEnv(fileText);
  assert(Object.keys(file).every((name) => PUBLIC_NAMES.includes(name)), "Production config file may contain only the two public Supabase VITE fields; remove other fields before releasing.");
  const viteEnv = Object.fromEntries(Object.entries(env).filter(([name]) => name.startsWith("VITE_")));
  assert(Object.keys(viteEnv).every((name) => PUBLIC_NAMES.includes(name)), "Unexpected VITE field in release environment; only the two public Supabase fields are permitted.");
  const config = { ...file, ...viteEnv };
  assert(PUBLIC_NAMES.every((name) => typeof config[name] === "string" && config[name]), "Connected release requires VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY in .env.production.local or the environment.");
  const url = new URL(config.VITE_SUPABASE_URL);
  assert(url.protocol === "https:" && !url.username && !url.password && url.pathname === "/" && !url.hash && !url.search, "Production Supabase URL must be an HTTPS origin.");
  const key = config.VITE_SUPABASE_PUBLISHABLE_KEY;
  let publicKey = /^sb_publishable_[A-Za-z0-9_-]{16,}$/.test(key);
  if (!publicKey && /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(key)) {
    try { publicKey = JSON.parse(Buffer.from(key.split(".")[1], "base64url").toString()).role === "anon"; } catch { /* fail below */ }
  }
  assert(publicKey, "Release browser key must be publishable or legacy anon; secret/service-role keys are forbidden.");
  return config;
}

export function verifyConnectedBundle(chunks, config) {
  const found = new Set();
  for (const [index, chunk] of chunks.entries()) {
    // Minifiers may choose single quotes, double quotes, backticks or escapes.
    // Inspect parsed literal values rather than guessing a quote spelling.
    const ast = ts.createSourceFile(`bundle-${index}.js`, chunk, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    assert.equal(ast.parseDiagnostics.length, 0, "Cannot parse built JavaScript for connected release verification.");
    const literal = (node) => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node));
    const visit = (node) => {
      if (ts.isPropertyAssignment(node)) {
        const name = ts.isIdentifier(node.name) || ts.isStringLiteral(node.name) ? node.name.text : undefined;
        if (PUBLIC_NAMES.includes(name) && literal(node.initializer)) {
          assert.equal(node.initializer.text === config[name], true, `Built ${name} differs from configured production value; rebuild connected assets.`);
          found.add(name);
        }
      }
      if (literal(node) || [ts.SyntaxKind.TemplateHead, ts.SyntaxKind.TemplateMiddle, ts.SyntaxKind.TemplateTail].includes(node.kind)) {
        const value = node.text;
        assert(!/sb_secret_[A-Za-z0-9_-]{16,}/.test(value), "A secret key pattern appears in built JavaScript.");
        for (const match of value.matchAll(/[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+/g)) {
          let payload;
          try { payload = JSON.parse(Buffer.from(match[1], "base64url").toString()); } catch { continue; }
          assert(payload.role !== "service_role", "A service-role JWT appears in built JavaScript.");
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(ast);
  }
  for (const name of PUBLIC_NAMES) assert(found.has(name), `Built JavaScript is missing the exact configured ${name} property; rebuild connected production assets.`);
}

export const DIST_BUDGETS = Object.freeze({ initial: 160_000, create: 260_000, total: 350_000 });
export const CREATE_ENTRIES = ["index.html", "src/features/projects/Projects.tsx", "src/features/sync/PropertyReels.tsx"];
export const PROXY_ENTRY = "src/editor/ProxyPanel.tsx";
export function manifestClosure(manifest, entries) {
  const visited = new Set(), files = new Set();
  const safeFile = (file) => {
    assert(typeof file === "string" && /^assets\/[A-Za-z0-9_.-]+\.(?:js|css)$/.test(file), "Unsafe or unsupported manifest asset path.");
    files.add(file);
  };
  const visit = (key) => {
    if (visited.has(key)) return;
    const item = manifest[key];
    assert(item && typeof item === "object", `Missing required build manifest entry: ${key}.`);
    visited.add(key); safeFile(item.file);
    for (const file of item.css ?? []) safeFile(file);
    for (const dependency of item.imports ?? []) visit(dependency);
  };
  entries.forEach(visit);
  return [...files].sort();
}
export function releaseAssetGroups(manifest) {
  const initial = manifestClosure(manifest, ["index.html"]);
  const create = manifestClosure(manifest, CREATE_ENTRIES);
  const proxy = manifestClosure(manifest, [PROXY_ENTRY]);
  assert(manifest["index.html"].isEntry === true, "Missing Vite HTML entrypoint.");
  for (const key of CREATE_ENTRIES.slice(1)) assert(manifest[key].isDynamicEntry === true, `Create workspace must remain a dynamic entry: ${key}.`);
  assert(manifest[PROXY_ENTRY].isDynamicEntry === true && !create.includes(manifest[PROXY_ENTRY].file), "Large-video preparation must remain on demand, outside the Create closure.");
  return { initial, create, withLargeVideo: [...new Set([...create, ...proxy])].sort() };
}
