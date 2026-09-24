# Historical API design

This directory contains the original [starter schema](db/schema.sql). It is not
the production database migration source or a runnable Fastify/FastAPI service.
Do not apply it to the live database as a schema update.

The implemented backend is in [services/supabase](../supabase):

- [Edge Functions and route/authentication map](../supabase/functions/README.md)
- [Ordered schema, RLS and RPC migrations](../supabase/migrations)
- [Database regression fixtures](../supabase/tests)
- [Studio API](../supabase/functions/studio/README.md)
- [Apple subscription handling](../supabase/functions/apple-subscriptions/README.md)

The original Redis queue, generic `/v1` server, shared Stripe/Apple credit-ledger
proposal and duration-band billing described by the starter design are not a
description of today's production system. Render jobs, entitlements, provider
cost records and subscription handlers use the current Supabase contracts.

For production evidence and migration/deployment sequencing, start with the
[24 September release record](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md).
