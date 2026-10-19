#!/usr/bin/env node
// Read-only preflight for one explicit migration. Never runs a DB write or
// repairs history. A same-name migration with a different version is already
// represented in the live ledger and must not be replayed by a bulk CLI push.
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

export function migrationDisposition(filename, ledger, expectedProject) {
  if (!ledger || ledger.project_id !== expectedProject || !Array.isArray(ledger.rows)) throw new Error("A read-only ledger capture from the exact target project is required.");
  const match = /^(\d{4,14})_(.+)\.sql$/.exec(basename(filename));
  if (!match) throw new Error("Select one explicitly named SQL migration.");
  const [, version, name] = match;
  for (const row of ledger.rows) if (typeof row.version !== "string" || typeof row.name !== "string") throw new Error("Invalid ledger metadata.");
  const versionRows = ledger.rows.filter(row => row.version === version);
  const nameRows = ledger.rows.filter(row => row.name === name);
  if (versionRows.some(row => row.name !== name)) throw new Error("This version is recorded under a different name. Reconcile the schema and ledger before applying anything.");
  if (versionRows.length > 1 || nameRows.length > 1) throw new Error("Ambiguous migration history requires manual reconciliation.");
  if (versionRows.length) return { version, name, disposition: "already_recorded", reapply: false };
  if (nameRows.length) return { version, name, disposition: "recorded_under_other_version", liveVersion: nameRows[0].version, reapply: false };
  if (ledger.rows.some(row => !/^\d+$/.test(row.version))) throw new Error("Unsupported historical version format requires manual reconciliation.");
  if (ledger.rows.some(row => BigInt(row.version) > BigInt(version))) throw new Error("Out-of-order migration: inspect dependencies and live definitions before applying it.");
  return { version, name, disposition: "not_recorded", reapply: false, requiresSchemaAndDependencyReview: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.length !== 6 || args[0] !== "--ledger" || args[2] !== "--project" || args[4] !== "--migration") throw new Error("Usage: check-migration-ledger.mjs --ledger <fresh metadata.json> --project <exact project id> --migration <one SQL file>");
  const ledger = JSON.parse(await readFile(args[1], "utf8"));
  const file = args[5];
  const result = migrationDisposition(file, ledger, args[3]);
  console.log(JSON.stringify({ ...result, sourceSHA256: createHash("sha256").update(await readFile(file)).digest("hex"), observedAtUTC: ledger.observed_at_utc, warning: "Read-only history guard. Never use this result as SQL-equivalence, deployment, or bulk db push approval." }, null, 2));
  // Nonzero for already-recorded/aliased files stops an accidental reapply.
  if (result.disposition !== "not_recorded") process.exitCode = 2;
}
