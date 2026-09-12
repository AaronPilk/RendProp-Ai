# Edge CI: deterministic x5c encoding fixture

## Finding and scope

Hosted run `34663177777`, Edge job `103469744402`, source `26c9459`,
reported **752 passed / 1 failed** at `2026-09-12T00:55:35Z`. The sole failure
was `_shared/applejws.test.ts`'s `S1: an x5c entry in base64URL rather than
base64 is refused`: `Expected function to reject`. All 27 account-deletion
tests passed; this is distinct from the previously corrected accessor-backed
`Deno.serve` fixture.

The test generated a random leaf certificate, encoded it with a base64URL
helper, and assumed that the output necessarily contained a URL-only alphabet
character. That is false: base64 and base64URL share 62 alphabet characters.
A generated certificate can use only that shared alphabet; removing optional
padding alone does not make `atob` reject it. The old assertion could therefore
fail on a valid chain or pass depending on freshly generated key/signature bytes.
No failing CI certificate bytes were retained, so the exact failed certificate
cannot be replayed. The invalid precondition is established from the fixture,
and runtime behavior was tested independently.

The exact official Deno **2.9.6** runtime rejects `-_8` and `-_8=` with
`InvalidCharacterError`, accepts standard `+/8=`, and accepts both `AA` and
`AA==` with identical bytes. Deno **2.7.13** behaves the same on these probes.
This is not evidence of a Deno 2.9 URL-alphabet decoder regression. The
production `applejws.ts` verifier is **unchanged**, including its existing
padding behavior. This unit does not claim new canonical-base64 enforcement.

## Test-only correction

- `ChainOptions.distinctBase64Alphabet` adds one signed, noncritical,
  test-specific certificate extension containing four consecutive `0xff`
  bytes. These guarantee a `/` base64 digit regardless of byte alignment;
  the URL encoding therefore necessarily contains `_`.
- The negative test asserts a URL-only digit is actually present before it
  calls the verifier. It also proves the exact same chain and payload verify
  successfully with standard base64. Only the textual x5c encoding changes
  in the negative case, which must return `401` / `unauthorized` with
  `certificate parse` in its error.
- No retry-until-green certificate factory, ignored case, production parser
  modification, workflow permission change, or weakened rejection assertion
  was introduced. The test module still contains **37 test cases**; the
  complete Edge suite's case count is unchanged at **753**.

## Executed proof

Official release asset:
`https://github.com/denoland/deno/releases/download/v2.9.6/deno-aarch64-apple-darwin.zip`

Downloaded ZIP SHA-256, matched to GitHub's official release-asset digest:
`213a2f304f04d3c9cb5220669afad138f60a5aab1fe80962abdeb8f35807a472`.

Verified runtime, not installed over the machine's default:
`/tmp/rendprop-deno296.EyhIbB/deno`
(resolved `/private/tmp/rendprop-deno296.EyhIbB/deno`). Its executable SHA-256:
`b3ac3bd206e48c26026cadd80c1367e96c149f9c66130952382a642b09fa8a71`.

From this worktree:

```sh
python3 tools/audit/run_apple_x5c_fixture.py --deno /tmp/rendprop-deno296.EyhIbB/deno
```

**Exit 0**, accepted receipt:
`/tmp/rendprop-apple-x5c-pid7olbo/receipt.json`.

The same full harness also passed under the pre-existing Deno 2.7.13 runtime:
`python3 tools/audit/run_apple_x5c_fixture.py --deno /opt/homebrew/bin/deno`,
exit 0, accepted receipt `/tmp/rendprop-apple-x5c-6k9mz3us/receipt.json`.

The harness uses actual source, actual WebCrypto signatures, and the actual
verifier with test-only trust roots. All Deno test commands type-check, use
cached dependencies, and deny network, subprocess, and filesystem-write access.

| Executed check | Result |
|---|---|
| Exact runtime alphabet probes | 1 passed, 0 failed |
| Actual Apple JWS test module | 37 passed, 0 failed |
| Same selected test with 100 newly minted chains | 100 passed, 0 failed |
| Mutant normalizes URL-only digits in actual decoder | Exit 1: `Expected function to reject` |
| Mutant supplies standard encoding as the negative fixture | Exit 1: URL-only digit precondition |
| Mutant removes leaf marker from the fixture chain | Exit 1: same-chain positive control refuses it |
| Restored actual Apple JWS module | 37 passed, 0 failed |

All source hashes were unchanged during execution. Mutants and logs remain
only in the isolated evidence directory. The first harness attempt correctly
failed because its last control expected the wrong error substring; that
attempt is retained at `/tmp/rendprop-apple-x5c-xh6gcc2w/receipt.json` with
`accepted: false`, not counted as successful evidence.

The complete 753-case suite and 22 function type-checks are the integration
agent's separate gate; this report does not claim their post-fix execution.
No iOS app code, Apple state, deployed function, database, provider routing,
or customer data was changed by this unit.
