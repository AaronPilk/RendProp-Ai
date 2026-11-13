# File-only rollout readback guard (O17)

`tools/deploy/verify-rollout-readback.py` compares complete explicitly supplied control documents and exact regular-file source/artifact hashes. It never collects API data, reads an auth cache, starts a CLI/VM, writes settings or deploys. The existing `check-migration-ledger.mjs` remains a separate migration-history preflight; neither tool proves the other's contract.

Run the closed controls:

```sh
python3 tools/deploy/test_verify_rollout_readback.py
```

Run a real file comparison with the separately reviewed contract's exact SHA:

```sh
python3 tools/deploy/verify-rollout-readback.py \
  --contract /absolute/path/rollout-contract.json \
  --contract-sha256 <64-lowercase-hex-sha256>
```

The CLI uses the actual current UTC time. There is no `--now`, freshness override, wildcard, ignored-key list or volatile-field exemption. It exits `0` only for `VERIFIED_FILE_ONLY`; a closed refusal exits `2`. Output contains status/codes, JSON/file paths and SHA256 values, never compared control values. At most the first64 differences are printed, with the full difference count; any difference still refuses.

## Input contract

The contract has exactly these keys:

```json
{
  "schema": "rendprop-rollout-readback-v1",
  "identity": {"environment": "production", "account": "exact-account", "resource": "exact-resource"},
  "baseline": {"path": "baseline.json", "sha256": "<exact-file-sha256>"},
  "actual": {"path": "readback.json", "sha256": "<exact-file-sha256>"},
  "max_age_seconds": 300,
  "inventories": [{"path": "/bindings", "key": "name"}],
  "changes": [{"path": "/image", "old": "exact-previous-image", "new": "exact-intended-image"}],
  "artifacts": {"worker.js": "<exact-file-sha256>"}
}
```

This is illustrative syntax, not an actual account, timestamp, hash or rollout authorization. Paths resolve relative to the contract. Both referenced snapshot files have exactly `identity`, `observed_at_utc` and `control`; `identity` must exactly match the contract's environment/account/resource object, and `control` must be the full chosen control document. Keep all settings, bindings, routes, secret names and unknown fields supplied by the admitted collector. A scope-specific adapter may wrap existing responses; it must not discard fields to make this comparison pass.

Both UTC observations must be at or before actual current time, at most the declared age (`1..300` seconds), with readback at or after baseline. Naive, future, stale or inverted observations refuse. Historical retained captures do not become fresh by being copied into a new file. Only the internal Python test API accepts an injected clock, and `verify(..., now=...)` always labels a successful result `HISTORICAL_REPLAY`. That is test evidence, not fresh rollout authority.

## Exact expected changes

Each change replaces one existing JSON Pointer with an exact `old` and `new` JSON value. The old value must match the baseline exactly; a no-op, missing path, duplicate path, overlapping parent/child path or wildcard refuses. Pointer escapes `~1` and `~0` are supported. There is no root replacement or append/delete operation. An intended array/object replacement requires its complete old and new value. Unlisted extra/missing fields, changed IDs/classes/types, null versus absent/array, boolean versus number and changed flags such as `ENABLED` all refuse.

Inventories are normalized only where explicitly declared. An object-array inventory uses an exact string key such as `name` or `id`; a string inventory uses `"key":"$value"`. Duplicate/missing/non-string identities refuse, and every field of every row remains compared. Array order elsewhere remains meaningful. Inventory declarations cannot overlap or repeat. Baseline inventory integrity is checked before any allowed replacement, so a replacement cannot conceal duplicate old identities.

## Source custody and privacy

The contract and each JSON input are SHA-bound, duplicate-key/nonfinite JSON refuses, and depth/node/size limits bound parsing. Every artifact must be a regular file, not a final-path symlink, and its exact SHA must match. Device/inode/size/mode/mtime/ctime are checked through the open descriptor and named path to reject a file changing during its read. The guard reads no environment credentials. It compares at a point in time; a rollout runner must separately serialize mutation and preserve its own command/approval/readback custody.

Secret-text bindings may contain exactly their name and type. Secret names may also appear in a distinct `secret_names`/`secretNames` string inventory; duplicate names refuse. Credential-value fields, secret-like plaintext bindings, private keys, bearer tokens and known capability-shaped strings refuse before mismatch reporting. API collectors must still omit actual secret values; this guard does not infer whether every arbitrary opaque string is secret. No file referenced in the artifact map should be an auth cache or credential store.

## Scope of a pass

A pass covers only the exact file documents, identity, freshness and artifacts supplied. It does not prove a collector queried every relevant endpoint, that sequential captures were atomic, that live state is still unchanged after reading, or that deployment/customer/media/financial acceptance occurred. Existing scope-specific collectors, complete API pagination checks, immutable intent, command-outcome reconciliation and actual source-byte readback remain necessary. Do not reinterpret the guard as a generic deploy or migration command.

The actual CPU17 retained policy/source proofs can be replayed against a clearly labelled historical clock without new service calls. Their original observation times must remain intact; the live CLI should refuse those older captures as stale. CPU17's separate root acceptance and original `module_part_type` refusal are not rewritten by this reusable tool.
