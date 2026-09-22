import assert from "node:assert/strict";
import { test } from "node:test";
import { StudioError } from "../src/data/config";
import { canRetainWorkspace } from "../src/workspace-refresh";

test("workspace retention is limited to known transient transport failures", () => {
  for (const code of ["network", "timeout"]) {
    assert.equal(canRetainWorkspace(new StudioError(code, "fixture")), true);
  }
  for (const status of [429, 500, 502, 503, 504, 599]) {
    assert.equal(canRetainWorkspace(new StudioError("request-failed", "fixture", status)), true);
  }
});

test("access loss, malformed responses, and unclassified failures clear cached workspace", () => {
  for (const code of ["membership-required", "session-expired", "sign-in-required", "stale-identity", "invalid-response", "identified-account-required"]) {
    assert.equal(canRetainWorkspace(new StudioError(code, "fixture")), false, code);
  }
  for (const status of [400, 401, 403, 404, 408, 422, 600]) {
    assert.equal(canRetainWorkspace(new StudioError("request-failed", "fixture", status)), false, String(status));
  }
  for (const value of [undefined, null, new Error("network"), { code: "network" }, new StudioError("request-failed", "fixture")]) {
    assert.equal(canRetainWorkspace(value), false);
  }
});
