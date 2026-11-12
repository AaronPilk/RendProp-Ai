# File-only source, CI and release binding (O17 / E6)

`tools/deploy/verify-release-binding.py` joins one reviewed source commit, raw GitHub Actions run/attempt and complete job pages, one immutable Worker version at100% traffic, and exact local plus retained served artifact bytes. It uses the existing rollout guard's bounded JSON/file/hash/freshness helpers. The v1 comparator, collectors, deployment commands, application code and workflow gates are unchanged.

```sh
python3 tools/deploy/test_verify_release_binding.py
python3 tools/deploy/verify-release-binding.py \
  --contract /absolute/path/release-binding.json \
  --contract-sha256 <reviewed64lowercasehex>
```

The checker never authenticates, reads credential stores, calls a service, invokes a subprocess, builds, deploys or writes settings. CLI success is `VERIFIED_FILE_BINDING`; refusal exits2 with a fixed code and no input values or paths. There is no CI exception/skip override or CLI historical clock. An internal test clock always labels success `HISTORICAL_FILE_BINDING`.

The helper import explicitly disables bytecode writing. A copied-tool CLI fixture checks that running the verifier creates no `.pyc`, `__pycache__` or other tool-directory files, without relying on an environment flag.

## Reviewed contract

The exact contract keys are `schema`, `identity`, `required_jobs`, `max_age_seconds`, `source`, `run`, `jobs_pages`, `release`, `artifacts`. Schema is `rendprop-release-binding-v1`.

- `identity` has exactly `repository`, `branch`, `workflow_path`, `source_sha`, `run_id`, `run_attempt`, `environment`, `account`, `resource`, `version`. Use a full40-character lowercase commit, exact run/attempt and immutable version UUID. No prefix, branch-only or successful-other-run substitution.
- `required_jobs` is an explicit, nonempty, duplicate-free list of exact required job names. The independently reviewed contract determines the required scope; the tool cannot discover omitted policy. The raw run must be completed/successful; every named job must exist exactly once and be completed/successful. Failed, running, cancelled, neutral or skipped required jobs refuse.
- `source`, `run`, `release` are `{ "path": "relative.json", "sha256": "<64hex>" }` references. All files and parent directories below the contract folder must be real, with no symlinks, absolute paths, traversal or URI paths. Input/file size and aggregate artifact limits remain bounded.
- `jobs_pages` is an ordered list of references extended with integer `page` and `per_page` fields. Pages must begin at1, be consecutive, have a consistent1..100 page size and the same raw `total_count`; every full page and final remainder must match. Total pages/counts, unique job IDs, exact run/attempt and head commit are checked. At most20 pages/1000 jobs are admitted. Do not relabel an incomplete collection with a smaller total.
- `artifacts` maps each relative artifact name to exactly `sha256`, `path` (local built bytes) and `readback_path` (retained actual served bytes). Both regular files are hashed; their bytes and sizes must match the same source/readback inventory entry. The set is exact and dynamic, never a hard-coded file count.
- `max_age_seconds` is1..300. Source and release captures keep their actual original observation times; both must be fresh and the release must follow source capture. Copying old evidence does not renew it.

This freshness window covers source/release observations, not the collection time of raw CI responses. A successful older CI run for the unchanged exact commit and exact attempt can remain the reviewed CI basis. This checker does not assert that CI metadata was fetched recently or that no newer attempt exists; collection custody must establish that separately. It still requires whole-run success: current failed PR40 and the old failed workflow cannot qualify, even where a separate operator previously accepted a narrowly scoped rollout exception.

## Capture files

The source capture has exactly `repository`, `branch`, `head`, `remote_head`, `tracked_clean`, `observed_at_utc`, `artifacts`. HEAD and remote HEAD must equal the reviewed commit; `tracked_clean` must be true. `artifacts` is the complete admitted build inventory mapping artifact names to SHA256 values.

The run file is the original GitHub Actions run response, including `id`, `run_attempt`, `repository.full_name`, `head_branch`, `head_sha`, `path`, `status`, `conclusion`. Each jobs file is the original page response with `total_count` and `jobs`; each job must retain its `id`, `name`, `run_id`, `run_attempt`, `head_sha`, `status`, `conclusion`. Extra API fields are retained in the hash-bound input, never used as a success shortcut. A hand-written `success:true` summary is insufficient.

The release capture has exactly `identity` (`environment`, `account`, `resource`), `source_sha`, `observed_at_utc`, `deployment`, `version`, `artifacts`. `deployment` retains the actual singular current-deployment response; its `versions` list must contain exactly the intended `version_id` at100 `percentage`. `version` retains the immutable version response with matching `id`. Each artifact row has exactly `name`, `sha256`, integer `bytes`, integer `http_status`200 and points through the contract to retained served bytes. Preserve the separate normal command-outcome receipt and existing whole-policy/hosted routing checks; they are not replaced by this identity binder.

## Scope limits

Snapshots remain untrusted source data. Matching SHA pins and identities do not authenticate a forged collector or prove that an operator chose every required job or service endpoint. Source capture and actual HTTP/API collection custody still need independent operator review. No atomic snapshot, deterministic/reproducible build, complete remote route inventory, media quality, purchase or customer acceptance is claimed.

This companion does not retrofit new release authority onto the completed0a3945dd rollout or turn its specifically approved scoped CI exception into an all-green run. Current PR40 remains unqualified when its required CI fails. No deployment or recollection is needed merely to test this file-only helper. Broader collector completeness remains open; the retained tour receipt explicitly says remote routes were not independently collected.
