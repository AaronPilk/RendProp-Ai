# Rendprop API / Backend

Modular monolith for v1 (Part 8.1). Postgres primary, Redis cache/queue, R2 object storage.

- `db/schema.sql` — full starter schema (identity, listings, render pipeline, sharing/metering, billing ledger, audit)
- API surface: Part 8.3 of the Master Build Prompt (`/v1`, Idempotency-Key on all creating/charging POSTs, RFC-7807 errors, HMAC-signed webhooks)
- Billing: Apple IAP (StoreKit 2 + App Store Server Notifications v2) and Stripe both credit a single server-authoritative `credit_ledger`. Renders debit by duration band × tier. No double-credit: unique constraints on `apple_txn_id` / `stripe_pi`.
- Metering: the player beacons streamed minutes → `share_views` → monthly `metering` rollup → cap enforcement (notify / Boost / auto-degrade to 720p).

Stack decision pending: Node (Fastify/Hono) vs Python (FastAPI). Either way — signed upload URLs (tus/R2 multipart), signed playback URLs, org-scoped RBAC on every endpoint.
