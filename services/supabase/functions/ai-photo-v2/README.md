# Retained-operation photo edits

Deploy only `ai-photo-v2` with `verify_jwt=true`. Its wrapper imports the strict named `handleAIPhoto` callback; importing the canonical module never starts a listener. The existing deployed canonical `ai-photo` v80 is not selected or modified by this deployment.

Only `/ai-photo-v2` (POST/OPTIONS) and `/ai-photo-v2/status` (GET/OPTIONS), including their `/functions/v1/` forms, map to the corresponding fixed canonical paths. Origin, query, headers, method, signal and the existing body stream are forwarded. The wrapper never reads, clones/tees, reserializes or redirects the request, and accepts no target URL or extra subroute.

A client buying new work must send `x-rendprop-photo-quality-protocol: retained-operation-v1`. This capability means the client durably saves the exact request and stable Idempotency-Key before dispatch and recovers that same operation after a lost/pending answer. It is not a claim based on the app build number. Exact historical results resolve before the new-work gate. A missing or unrecognized capability refuses fresh work with 409 `conflict`, `recovery_protocol_required:true`, `required_photo_quality_protocol`, `no_provider_dispatch:true`, and `failure_phase:photo_recovery_protocol`; no supplier is dispatched. Existing pending reads without the capability cannot initiate a judge. Paid helper stages also check the capability after their serving replay boundary and unwind their existing feature receipt on refusal.

The strict callback retains ordinary caller Auth, current library/identity, exact request hash, input/geometry, payment, consent/cancellation fences and prospective QC. No cap, schema, funding, flag or provider route is changed here. The client must not advertise this protocol until its durable recovery is implemented. Current Studio moves only after its journal is verified.

Offline reviewed deployment staging:

```sh
services/supabase/deploy-functions.sh --functions ai-photo-v2 --create-new ai-photo-v2
```

No deployment occurs without root's deliberate `--run`; canonical `ai-photo` must not be selected as a side effect. Source readback and JWT-policy verification remain mandatory.
