# Studio owner-media read bridge

Additive route: `GET /functions/v1/studio/media?org_id=<uuid>&listing_id=<uuid>&offset=0`.
Deploy with JWT verification enabled. The handler also verifies the caller with
Supabase Auth, current membership, deletion state, and user-token RLS queries.
The optional `X-Org-Id` must match `org_id`; it never grants authority.

No migration or new secret is required. Existing private/render R2 credentials are
used server-side. This function does not issue upload tickets, create generation
jobs, change billing, publish, or delete anything. Its rate-limit RPC is the only
counter mutation.

Each page examines up to 50 photos, 50 completed capture assets and 50 stored
renders. `next_offset` is null at the end. Offset increments by 50. Signed read
links expire in 600 seconds and may only reference canonical objects under this
organization/listing prefix. Unlinked outputs are counted in `unavailable_count`,
not turned into unrestricted object capabilities. At the maximum paging boundary,
an oversized collection fails visibly rather than claiming it is complete.

```bash
deno check services/supabase/functions/studio/index.ts
deno test --deny-net --deny-run --deny-write services/supabase/functions/studio/handler.test.ts
```

The dependency-injected tests prove the route contract and rejection paths, not
the production database's RLS configuration. Connected acceptance also needs a
real same-account web login, selected-workspace checks, and R2 browser GET CORS.
See `docs/web-client/release-2026-09-14/README.md` before deploying. Do not redeploy all other
functions or alter their JWT flags as part of this additive web route.
