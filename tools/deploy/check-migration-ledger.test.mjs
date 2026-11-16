import { test } from "node:test";
import assert from "node:assert/strict";
import { migrationDisposition } from "./check-migration-ledger.mjs";
const ledger = { project_id: "synthetic-project", rows: [{ version: "20261005011911", name: "app_video_rejected_submission_release" }, { version: "20261005202324", name: "private_internal_testing_sponsorships" }] };
test("live name aliases block reapplying the existing authority migration", () => {
 const r = migrationDisposition("20261005200559_private_internal_testing_sponsorships.sql", ledger, "synthetic-project"); assert.equal(r.disposition, "recorded_under_other_version"); assert.equal(r.liveVersion, "20261005202324"); assert.equal(r.reapply, false);
});
test("exact ledger rows are not SQL replay permission", () => {
 assert.equal(migrationDisposition("20261005011911_app_video_rejected_submission_release.sql", ledger, "synthetic-project").disposition, "already_recorded");
});
test("pending migration still requires schema and dependency review", () => {
 const r = migrationDisposition("20261005215707_brokerage_pricing_service_acl.sql", ledger, "synthetic-project"); assert.equal(r.disposition, "not_recorded"); assert.equal(r.requiresSchemaAndDependencyReview, true);
});
test("wrong project, colliding name/version and out-of-order migration fail closed", () => {
 assert.throws(() => migrationDisposition("20261005215707_new.sql", ledger, "other-project"));
 assert.throws(() => migrationDisposition("20261005011911_other_name.sql", ledger, "synthetic-project"));
 assert.throws(() => migrationDisposition("20261005000000_unrecorded_older.sql", ledger, "synthetic-project"));
 assert.throws(() => migrationDisposition("0055_older_legacy_price_seed.sql", ledger, "synthetic-project"));
 assert.throws(() => migrationDisposition("*.sql", ledger, "synthetic-project"));
});
