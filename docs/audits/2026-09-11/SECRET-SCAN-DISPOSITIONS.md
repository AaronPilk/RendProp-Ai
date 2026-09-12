# Six historical Gitleaks dispositions — 2026-09-11

## Change and reason

GitHub Actions run `34662282586`, job `103467084959`, at source `2ca9c7a6219393845382928fb448d6bead7d4a51` failed its **actual scan**, reporting six findings. This was not a license or action-setup failure. Its downloaded scanner was Gitleaks **8.24.3**.

Each match was independently classified from its historical source. `.gitleaksignore` contains exactly the six scanner-reported `commit:path:rule:line` fingerprints. There is no rule exemption, path exemption, skipped commit, global allowlist, workflow change or history rewrite. Secret scanning remains enabled in `.github/workflows/ci.yml:420–430`, with a full-depth checkout. New findings require their own review; these six historical dispositions do not authorize suppressing future matches.

## Disposition evidence — historical line numbers

The first five findings belong to `bcba8040bfa10eb0f199e83aa2787fe0f15d5ba9`; the last belongs to `4e4776dbdd8bf3e7408e805c2d313e1b46087b76`. Both commits are ancestors of the earlier `71f9eb7` audit baseline (`git merge-base --is-ancestor` returned 0 for each).

| Rule / source | Classification and evidence |
| --- | --- |
| `curl-auth-header` — `docs/handoff/launch-P2.md:517` | **Documentation false positive, not an exposed Authorization credential.** Line 517 is a negative-test curl command with no auth header; line 518 is its missing-auth JSON error response. The companion command at line 521 supplies an explicit invalid placeholder, not a real token. The scan spans this example. An earlier handoff treating line 518 as a potentially real header is corrected by this source review. |
| `generic-api-key` — `services/supabase/functions/_shared/applejws.test.ts:924` | **Test identifier, not an API key.** A UUID is assigned to `appAccountToken` at 926 and its decoded equality asserted at 930. `buildChain()` at 923 creates a local test certificate chain through WebCrypto key generators at 152–153 and 236–243; verification explicitly trusts that test root at 929. |
| `generic-api-key` — `services/supabase/functions/apple-subscriptions/notify.test.ts:293` | **Test identifier.** The UUID is an app-account-token fixture inside the local `tx` / `facts` helpers (33, 73). The test calls `summariseNotification` at 294 and asserts signed payload/token-like material does not survive serialization at 309–312. No API key is used here. |
| `private-key` — `services/supabase/functions/admin/probe.test.ts:178` | **Generated-key PEM template, not committed private-key bytes.** `freshP8Pem()` calls `crypto.subtle.generateKey` at 169, exports the newly generated key at 174, encodes its body at 175–177 and interpolates that body into a PEM envelope at 178. The test invokes the generator at 191. The source contains the envelope/template, not a provider key. |
| `jwt` — `services/supabase/functions/admin/probe.test.ts:275` | **Fixed JWT-shaped sanitizer fixture.** The literal is passed to `sanitize` at 276; each sufficiently long segment must be absent from its result at 277–278. This test does not use that fixture to authenticate to a provider. No claim of cryptographic signature validity or invalidity is needed for this disposition. |
| `jwt` — `apps/ios/Rendprop/Config.swift:33` | **Deliberately public client configuration.** It is the `supabaseAnonKey` fallback (29–34). Internal decoding confirms its declared role is `anon`, not `service_role`; the surrounding code intentionally ships it in the client. Decoding is not signature verification. This disposition does not assert live permissions, current validity, or that RLS is correctly configured. |

No matched credential bytes, JWT identity claims or personal data are reproduced here. None of these six matches establishes an exposed private production credential requiring rotation. Any independent credential-rotation operational gate from a different finding remains separate.

## Actual scanner verification

`command -v gitleaks` initially returned 1. The official **8.24.3 Darwin arm64** release archive was downloaded to an owned temporary directory and verified against its official published checksums before execution. It was not installed globally.

- Archive SHA-256: `b90f13bb8c90ab72083d9b0c842e39dafb82c0e5c3f872f407366b7a58909013`.
- Extracted executable SHA-256: `af9afd0ae3a0ff6d7f08c4ec4e28686b7e4de6962fe1eadecc497d15cdf731e2`.
- `gitleaks version` printed `8.24.3`; `gitleaks git --help` confirmed the invoked flags.
- Source was not shallow; `git rev-list --count HEAD` returned 316. Gitleaks reported 291 scanned commits and **13,142,006 bytes** in each complete source-history control below.

| Actual control | Expected / observed |
| --- | --- |
| Separate clean detached worktree at exact `2ca9c7a`, no `.gitleaksignore` | Exit **1**, exactly the six reviewed fingerprints. |
| Same full `HEAD` history with the six-fingerprint ignore file | Exit **0**, zero remaining findings. |
| Independent owned temporary repository with identical ignore-file bytes and a newly generated, inert JWT-shaped fixture | Exit **1**, exactly one `jwt` finding. The fixture intentionally uses the **same `apps/ios/Rendprop/Config.swift` path and line 33** as a reviewed match, but a new commit. This proves the ignore is not a path/rule/line-wide exemption. No actual account credential was copied. |

The independent fixture commit was `5b6c17b47dff5a6c36fb5e43a905da0cf1278794`. Its sole reported fingerprint was `5b6c17b47dff5a6c36fb5e43a905da0cf1278794:apps/ios/Rendprop/Config.swift:jwt:33`, which is **not** in `.gitleaksignore`.

**A failed control caught a real harness mistake before acceptance.** Passing an empty `--gitleaks-ignore-path` does not override the source directory's own `.gitleaksignore`: Gitleaks also loads that file. The first no-ignore control therefore unexpectedly returned zero, and the asserting harness exited nonzero. The accepted proof uses a separate clean detached source worktree with no ignore file. This matches [upstream 8.24.3 loading code](https://github.com/gitleaks/gitleaks/blob/v8.24.3/cmd/root.go#L226-L246), not an assumption about flag precedence.

The fingerprint mechanism and flags were checked against the [version-pinned upstream documentation](https://github.com/gitleaks/gitleaks/blob/v8.24.3/README.md#gitleaksignore).

## Reproduce / retained evidence

Local evidence directory: `/tmp/rendprop-gitleaks-8.24.3.aDEU2H/`.

- `verify.py`: asserting orchestration, no token probes, fresh synthetic negative fixture.
- `receipt.json`: accepted result, exact commands, source/ignore/binary hashes and sanitized finding metadata.
- `without-ignores.json`, `with-six-fingerprints.json`, `independent-new-commit.json`: reports containing only rule, file, line, commit and fingerprint. A custom report template excludes matches, secret values and author fields.
- `baseline/`: detached exact-source worktree, retained rather than deleted.
- `independent-fixture-hpy5q32_/`: inert negative-control repository, retained outside Rendprop Git history.

The source scan command is:

```sh
/tmp/rendprop-gitleaks-8.24.3.aDEU2H/gitleaks git \
  --redact=100 --no-banner --no-color --log-opts=HEAD \
  --gitleaks-ignore-path .gitleaksignore .
```

The controlled harness removes inherited `GITLEAKS_*` overrides from its subprocess environment. It requires the exact scanner version, six syntactically complete unique fingerprints, the expected exit codes, and exact findings. It does not treat a printed message as a pass. Reports are sanitized before display. Temporary evidence may disappear after reboot; this committed disposition records the substantive result and the exact narrow configuration.

This is local scanner proof for the specified source, not a claim that a subsequent GitHub Actions run passed. The integration owner must rerun CI after cherry-picking this unit. No production request, credential rotation, App Store action or customer-data mutation was performed.
