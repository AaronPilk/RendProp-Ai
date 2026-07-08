# ROAM Infra

IaC (Terraform/Pulumi) for: Cloudflare R2 buckets (raw / intermediates / renditions), Cloudflare Stream, WAF/DNS, Postgres, Redis, Modal/RunPod worker configs, envs (dev/staging/prod).

Key constraints (Parts 7, 16):
- R2 zero-egress is the economics — never front media with an egress-charging origin
- Batch intermediates (R2 Class-A op cost) — no per-frame file writes
- Signed playback URLs, hosting TTL auto-expiry
- Budget alerts per subsystem; per-job cost ceilings; scale-to-zero on idle
