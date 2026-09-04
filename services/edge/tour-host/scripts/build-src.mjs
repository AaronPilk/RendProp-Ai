// build-src.mjs — transpile src/*.ts into importable ESM for the check scripts.
//
// Shared by check-unbranded.mjs and check-routes.mjs so both test the REAL
// source, with no build step and no new dependency (the repo's own TypeScript
// does the transpile). Type errors are `npm run typecheck`'s job; this only
// strips types, so the checks stay fast.

import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = resolve(HERE, "..");
const SRC = join(ROOT, "src");

/**
 * Transpile every src/*.ts into `node_modules/.cache/<cacheDir>` and return a
 * loader: `(name) => import(...)` for the built module, e.g. load("player").
 */
export function buildSrc(cacheDir) {
  const out = join(ROOT, "node_modules", ".cache", cacheDir);
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const file of readdirSync(SRC).filter((f) => f.endsWith(".ts"))) {
    const source = readFileSync(join(SRC, file), "utf8");
    const { outputText, diagnostics } = ts.transpileModule(source, {
      fileName: file,
      reportDiagnostics: true,
      compilerOptions: {
        target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.ESNext,
        isolatedModules: true,
      },
    });
    if (diagnostics && diagnostics.length) {
      for (const d of diagnostics) {
        console.error(`transpile ${file}: ${ts.flattenDiagnosticMessageText(d.messageText, " ")}`);
      }
      throw new Error(`could not transpile src/${file}`);
    }
    // Node does not resolve extensionless relative imports.
    const js = outputText.replace(
      /(\bfrom\s*["'])(\.\.?\/[^"']+?)(["'])/g,
      (m, pre, spec, post) => (/\.(js|mjs|json)$/.test(spec) ? m : `${pre}${spec}.js${post}`),
    );
    writeFileSync(join(out, file.replace(/\.ts$/, ".js")), js);
  }
  return (name) => import(pathToFileURL(join(out, `${name}.js`)).href);
}
