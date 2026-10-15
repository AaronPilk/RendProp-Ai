# Existing photo quality review

Actor-authenticated calibration only; deploy with `verify_jwt=true`. This entrypoint does not import or deploy `ai-photo/index.ts`, generate images, consume photo credits, activate prospective QC, or change the old output pointer/provenance/selection.

`POST /photo-quality-review` requires a fresh named user's bearer JWT, `x-org-id` identifying the current selected library, `content-type: application/json`, and `x-rendprop-ai-consent: photo-quality-review-v1`. The consent header attests the caller's current explicit grant; it is not a server-stored revocation history. Request cancellation fences unsent continuation. The only outer fields are `generation_request_key` and `generation_request_body`, containing the exact historical generation body, including its owned original asset. Maximum wire size is 12,100,000 UTF-8 bytes and decoded source is at most 9,000,000 bytes.

The existing helpers verify current editor/deletion/library authority, exact completed request hash, owned saved `photo_output`, original source authority, and confirmed original generation reservation/ledger. They retain a separate private calibration copy and immutable context. One preallocated check may start CPU preparation and one eligible normally funded judge through the existing lease/bind fences. A lost or ambiguous answer never buys a new generation or another check. Calibration can run while prospective policy is disabled, but still requires the approved eligible judge and normal funding. No grant or quota reset is performed.

`GET /photo-quality-review/status?check_id=<UUID>` requires fresh actor authentication and the current selected library. It is read-only: no CPU kickoff, judge, funding or copy. Renewed AI consent is not required to inspect saved status. Only calibration checks are returned. Terminal responses contain IDs, state, verdict, `purpose:calibration` and `publishable:false`, never media/base64/asset URLs. Pending uses the existing scoped 409 envelope. All responses are `Cache-Control:no-store`.

Offline staging and reviewed first deployment use:

```sh
services/supabase/deploy-functions.sh --functions photo-quality-review --create-new photo-quality-review
```

The command is offline unless root deliberately supplies `--run`; source readback and the declared JWT policy remain mandatory. The separate private CPU/worker dependencies must be reviewed/deployed by root. Tests use only synthetic HTTP transports, and make no real provider or hosted calls.
