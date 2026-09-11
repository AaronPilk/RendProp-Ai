# Live upload proof — September 11, 2026

## Outcome

**PASS for the controlled transport/publication path, not a whole-app release GO.**
Three generated fixtures moved through live Supabase v35 → Cloudflare upload
gateway → R2 → completion. App-render publication and its replay produced one
render and one job. Both branded and unbranded hosted pages returned200 with a
video player. No camera media, paid AI route, GPU, customer record, deletion,
bulk-abort, deployment, production spatial budget or Apple setting was touched.

This supersedes the earlier "no file transferred" and v33 rollback status. It
does not mean outstanding legacy tickets or iPhone background upload are fixed.

## Independently read back

- Supabase project`ymgqpbnjpztwjsyvceld`: uploads ACTIVE35, verify_jwt=true;
  spatial ACTIVE2, verify_jwt=false with handler authentication.
- All10 uploads bundle files and all7 spatial bundle files compared byte-for-byte
  against8263e25, matching exactly. This checks deployed code, not just version
  labels or another agent's assertion.
- Gateway domain`uploads.rendprop.com` enabled on`rendprop-upload-gateway`.
  Bindings UPLOADS→rendprop-uploads; RENDERS→rendprop-renders.
- Active gateway version is **c7a84e03-6ec1-4dd7-b980-a88027f026e4**, deployed
  20:41:49UTC. Claude's72489ff2 was the initial upload; two secret-triggered
  deployments followed. The difference is not evidence of another code change.
- Gateway origin/allowed-origin are both the custom hostname; Supabase
  origin/allowed-origin are the expected project. Required secret names present.
  Secret values were not printed. The returned ticket's HMAC independently
  matches the protected shared-capability file; the live Worker accepted it.
- Tour-host active version **0e6b2f90-5911-4e77-934f-8575c9d982e2**,20:46:15UTC.
- Spatial runtime readback remains disabled, daily/org-month budgets0,
  job_cap_cents600. This is per attempt, not a per-capture invoice ceiling.

## Actual fixture and assertions

Dedicated anonymous fixture identity, isolated from the owner's account:

- user9a6cfd65-58ad-42a3-b83b-3b791eb305b6
- org34dc23e9-444b-4088-a004-3f79de071267
- listing3f5e3bf8-54d9-4d82-a9c9-6ecf412dfbb3
- run c0210924-e11f-4e93-adf3-94c547b5b5d3

The listing is explicitly named SYNTHETIC UPLOAD PROOF, not a real address.
Only solid-purple generated media was used. The synthetic public tour is retained
as test evidence; no automatic production cleanup was performed.

| Fixture | Actual bytes | Path | Result |
| --- | ---: | --- | --- |
| 2×2 PNG |73| private single upload + server copy | uploaded=true, v2, exact size |
| 64×64 one-second MP4 |1,855| public render single upload + server copy | exact public object SHA-256 |
| Same synthetic MP4 |1,855| explicitly requested multipart, one final part | init, part, assembly and completion pass |

All pre-transfer completion probes returned409. Ticket replays before transfer
returned200 with the same asset ID. Completion replays returned the same final
asset/key, including after restarting the harness. Publication and replay returned
the same render3771ed1d-2032-457f-b75d-883374a41ac2 and job ID; independent SQL
found one render and one distinct job for this fixture listing.

The MP4's final downloaded SHA256 was
`79b436d2d8149c82f0bc13ea14150b0f3a10c94aa3a6fced25684b62056af091`.

Independent database assertions: three completed v2 assets, three tickets,
zero held bytes, **5,711 spent bytes** =2×73+2×1855+1855. Single-upload copying
is accounted separately; multipart assembly carries no extra payload write
charge in this ledger. These are the code's write-byte ledger values, not an R2
invoice or a claim of zero network ingress.

## Initial failure was investigated, not hidden

Python's default urllib user-agent received HTTP403/error1010 before Worker
dispatch. Exact fixture-row readback showed planned,0spent,146held, so no R2
write was authorized. The protected response confirmed the1010 classification.
The test client now identifies itself truthfully as`Rendprop-Upload-Proof/1.0`.
The same ticket then returned200; no firewall rule was disabled or changed.
[Cloudflare documents1010 as client-signature blocking](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/).

A separate **compiled Swift/Foundation URLSession** test, with its default
user-agent untouched, PUT the already-stored synthetic MP4 capability and got
200 plus the durable ETag. Independent SQL still showed3tickets/5711spent/0held:
this replay did not spend another write. This is a macOS Foundation networking
check, not an iPhone background-session or camera acceptance test.

## Commands and durable receipts

From`live-upload-proof-20260911`:

```sh
python3 -m py_compile tools/audit/prove_live_upload.py
python3 tools/audit/prove_live_upload.py --negative-control
# Deliberate assertion: exit1, required by an outer asserting subprocess check.
python3 tools/audit/prove_live_upload.py --live \
  --private-directory /Users/pilksclaes/LocalSpatialExperiments/live-upload-proof-20260911
# exit0; real HTTP outcomes saved, not inferred from logs.
swiftc -parse-as-library tools/audit/prove_native_gateway.swift \
  -o /tmp/rendprop-native-gateway-proof-20260911
/tmp/rendprop-native-gateway-proof-20260911 \
  /Users/pilksclaes/LocalSpatialExperiments/live-upload-proof-20260911
# exit0; HTTP200 with ETag using actual URLSession.
```

- [Sanitized HTTP receipt](LIVE-UPLOAD-HTTP-RECEIPT-20260911.json)
- [Independent database receipt](LIVE-UPLOAD-DATABASE-RECEIPT-20260911.json)
- Credentials, signed URLs and error bodies stay in a0600 local private state
  file outside Git. Do not paste that file into a handoff or issue.
- The harness is resumable but intentionally refuses to repeat an ambiguous
  signup or PUT. Fresh allocations are never inferred from a missing receipt.
  The original403 replay was manually reviewed only after a zero-dispatch DB
  readback; that is not a generic network retry policy.

## Still open

1. Existing v1 tickets need exact-ticket cancellation/reticketing; v2 needs
   receipt reconciliation without allocating a replacement. General iOS upload
   recovery is being fixed on`fix/upload-rollout-recovery-20260911`. No existing
   customer ticket was cancelled here. This fixture does not create v1 rows by
   privileged SQL or pretend the new endpoint exists in deployed v35.
2. Multipart fixture has one final part. Multi-part ordering, concurrent claims,
   oversized-body rejection and mixed-version paths require the isolated
   regression suites; this receipt is not evidence those were rerun today.
3. Actual iPhone foreground/background suspension, cellular/Wi-Fi handover and
   post-termination recovery remain device acceptance work.
4. Staging cleanup is journaled, not claimed deleted by completion. Sweep/cron
   and lifecycle rules must be verified separately; do not bulk-abort to make
   this report look clean.
5. Spatial deletion0039/me integration, durable provider journal0041, cloud
   worker, real153-frame reconstruction and real-room viewer acceptance remain
   separate work. Neither a purple video nor a successful upload is a 3D room.
6. No Apple operation occurred. This test does not establish any newer phone
   build or alter the pending App Review submission.
