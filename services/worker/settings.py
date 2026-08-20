#!/usr/bin/env python3
"""
Central config for the Rendprop server-side RENDER WORKER.

One place to read every env var the worker needs: Supabase (service role), R2
(S3 API), Cloudflare Stream, the ffmpeg encode knobs, the infra cost knobs, and
where the sibling AI pipeline lives (services/pipeline) so the worker can reuse
its declutter/restage/hero + cost-metering stack.

Loading order matters: `load_env()` runs at import and populates os.environ from
`worker/.env` (if present) WITHOUT overriding anything already set. That means:
  • in prod, every value comes from the container/process env (Docker -e /
    Modal secrets / Cloud Run env) and the .env file is a no-op;
  • in local dev, worker/.env seeds os.environ — and because we load it before
    the AI pipeline is imported, the pipeline's own `config.SETTINGS` (built at
    import from os.environ) sees the SAME provider keys. One .env, both halves.

Never ship SUPABASE_SERVICE_ROLE_KEY or any provider key to the iOS app
(BACKEND-ARCHITECTURE.md §4).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


# ── .env loader (stdlib only, mirrors the pipeline's) ─────────────────────────

def load_env(path: Path | None = None) -> None:
    """Populate os.environ from a .env file if present (does NOT override)."""
    path = path or (Path(__file__).parent / ".env")
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


# Load worker/.env immediately so anything imported after us (including the AI
# pipeline) reads a fully-populated os.environ.
load_env()


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _bool(name: str, default: bool = False) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


# The Postgres schema the Rendprop tables live in. ALL Supabase REST calls target
# it via Accept-Profile (reads) / Content-Profile (writes). NOT `public`.
DB_SCHEMA = os.environ.get("SUPABASE_DB_SCHEMA", "rendprop")


@dataclass(frozen=True)
class Settings:
    # ── Supabase (service role — server side only) ──
    supabase_url: str = ""
    supabase_service_role_key: str = ""
    db_schema: str = DB_SCHEMA

    # ── Cloudflare R2 (S3-compatible) ──
    cloudflare_account_id: str = ""
    r2_access_key_id: str = ""
    r2_secret_access_key: str = ""
    r2_bucket_uploads: str = "rendprop-uploads"
    r2_bucket_renders: str = "rendprop-renders"
    r2_endpoint: str = ""            # derived from account id if blank
    r2_presign_expiry_s: int = 3600  # lifetime of the GET url handed to Stream

    # ── Cloudflare Stream ──
    cloudflare_stream_token: str = ""
    stream_poll_interval_s: float = 4.0
    stream_timeout_s: int = 900
    stream_require_ready: bool = False  # if false, register + move on (poll async)

    # ── ffmpeg encode (mirrors apps/ios .../RenderEngine.swift) ──
    ffmpeg_bin: str = "ffmpeg"
    ffprobe_bin: str = "ffprobe"
    encode_long_edge: int = 1280
    encode_fps: int = 60
    encode_bitrate: str = "14M"
    encode_preset: str = "medium"
    tonemap_hdr: bool = False        # HDR->SDR tonemap (needs zscale/tonemap); TODO

    # ── AI pipeline reuse ──
    pipeline_dir: str = ""           # default: ../pipeline relative to this file
    hero_seconds: int = 5

    # ── Infra cost knobs (cents) — see infra_costs.py ──
    render_compute_cents_per_min: float = 0.5   # server encode compute (estimate)
    render_compute_provider: str = "modal"
    stream_store_cents_per_min: float = 0.5     # Cloudflare Stream storage $0.005/min

    # ── Worker loop ──
    poll_interval_s: float = 5.0
    run_once: bool = False           # process one job then exit (serverless/triggered)
    claim_statuses: tuple = ("created", "queued")
    workdir: str = "/tmp/rendprop-worker"

    @classmethod
    def from_env(cls) -> "Settings":
        account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
        endpoint = os.environ.get("R2_ENDPOINT", "")
        if not endpoint and account:
            endpoint = f"https://{account}.r2.cloudflarestorage.com"
        pipeline_dir = os.environ.get("PIPELINE_DIR", "") or str(
            (Path(__file__).parent.parent / "pipeline").resolve()
        )
        return cls(
            supabase_url=os.environ.get("SUPABASE_URL", "").rstrip("/"),
            supabase_service_role_key=os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
            db_schema=DB_SCHEMA,
            cloudflare_account_id=account,
            r2_access_key_id=os.environ.get("R2_ACCESS_KEY_ID", ""),
            r2_secret_access_key=os.environ.get("R2_SECRET_ACCESS_KEY", ""),
            r2_bucket_uploads=os.environ.get("R2_BUCKET_UPLOADS", "rendprop-uploads"),
            r2_bucket_renders=os.environ.get("R2_BUCKET_RENDERS", "rendprop-renders"),
            r2_endpoint=endpoint,
            r2_presign_expiry_s=_int("R2_PRESIGN_EXPIRY_S", 3600),
            cloudflare_stream_token=os.environ.get("CLOUDFLARE_STREAM_TOKEN", ""),
            stream_poll_interval_s=_float("STREAM_POLL_INTERVAL_S", 4.0),
            stream_timeout_s=_int("STREAM_TIMEOUT_S", 900),
            stream_require_ready=_bool("STREAM_REQUIRE_READY", False),
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", "ffmpeg"),
            ffprobe_bin=os.environ.get("FFPROBE_BIN", "ffprobe"),
            encode_long_edge=_int("ENCODE_LONG_EDGE", 1280),
            encode_fps=_int("ENCODE_FPS", 60),
            encode_bitrate=os.environ.get("ENCODE_BITRATE", "14M"),
            encode_preset=os.environ.get("ENCODE_PRESET", "medium"),
            tonemap_hdr=_bool("TONEMAP_HDR", False),
            pipeline_dir=pipeline_dir,
            hero_seconds=_int("HERO_SECONDS", 5),
            render_compute_cents_per_min=_float("RENDER_COMPUTE_CENTS_PER_MIN", 0.5),
            render_compute_provider=os.environ.get("RENDER_COMPUTE_PROVIDER", "modal"),
            stream_store_cents_per_min=_float("STREAM_STORE_CENTS_PER_MIN", 0.5),
            poll_interval_s=_float("POLL_INTERVAL_S", 5.0),
            run_once=_bool("RUN_ONCE", False),
            workdir=os.environ.get("WORKER_WORKDIR", "/tmp/rendprop-worker"),
        )

    # ── convenience ──
    @property
    def has_supabase(self) -> bool:
        return bool(self.supabase_url and self.supabase_service_role_key)

    @property
    def has_r2(self) -> bool:
        return bool(self.r2_endpoint and self.r2_access_key_id and self.r2_secret_access_key)

    @property
    def has_stream(self) -> bool:
        return bool(self.cloudflare_stream_token and self.cloudflare_account_id)


SETTINGS = Settings.from_env()
