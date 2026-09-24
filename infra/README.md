# Rendprop infrastructure

This directory is an infrastructure index, not a Terraform/Pulumi implementation.
There are no infrastructure modules to apply here. The original infrastructure
proposal does not establish a provisioned Redis, RunPod or generic render fleet.

Current configuration and operating contracts live with their services:

| Component | Configuration / instructions |
| --- | --- |
| Studio assets and custom domain | [Studio README](../apps/studio/README.md), [Wrangler config](../apps/studio/wrangler.jsonc) |
| Public website and hosted tours | [tour-host README](../services/edge/tour-host/README.md) |
| Upload gateway | [Worker source/config](../services/edge/upload-gateway) |
| Database, auth and APIs | [Supabase functions](../services/supabase/functions/README.md), [migrations](../services/supabase/migrations) |
| Optional render worker | [worker README](../services/worker/README.md) |
| Gated spatial controller and GPU sandbox | [spatial-worker README](../services/spatial-worker/README.md) |

See the [24 September Studio release](../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
for verified production versions. A checked-in configuration or deployment recipe
does not establish that a worker is running. Keep secrets in the appropriate
server environment, preserve private media access and cost controls, and verify
the target account, routes, runtime gates and live readback for each release.
