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

def parse_env_line(line: str) -> tuple[str, str] | None:
    """One dotenv line → (key, value), or None for blanks/comments.

    Handles the shapes people actually write (audit F-G-11: a trailing
    ``# comment`` used to become part of the value, so ``MAX_GEN_COST_PER_JOB_CENTS=2500
    # cap`` silently fell back to the default):
      • ``export KEY=value``
      • ``KEY="quoted value"`` / ``KEY='quoted'`` (quotes stripped, ``#`` inside kept)
      • ``KEY=value   # inline comment`` (comment stripped — a ``#`` preceded by
        whitespace ends an unquoted value; ``a#b`` stays intact)
    """
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    if s.startswith("export "):
        s = s[len("export "):].lstrip()
    k, _, v = s.partition("=")
    k = k.strip()
    if not k or any(ch.isspace() for ch in k):
        return None
    v = v.strip()
    if v[:1] in ('"', "'"):
        q = v[0]
        end = v.find(q, 1)
        v = v[1:end] if end != -1 else v[1:]
    else:
        for i, ch in enumerate(v):
            if ch == "#" and (i == 0 or v[i - 1].isspace()):
                v = v[:i].rstrip()
                break
    return k, v


def load_env(path: Path | None = None) -> None:
    """Populate os.environ from a .env file if present (does NOT override)."""
    path = path or (Path(__file__).parent / ".env")
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        kv = parse_env_line(line)
        if kv:
            os.environ.setdefault(kv[0], kv[1])


# Load worker/.env immediately so anything imported after us (including the AI
# pipeline) reads a fully-populated os.environ.
load_env()


class ConfigError(RuntimeError):
    """An env var is SET but unusable. Never silently defaulted (audit F-G-11).

    A cost ceiling or a QC threshold that quietly falls back to its default is
    how an unattended bill runs away: the operator lowers the cap to $5 for
    launch, the value never applies, and nothing says so. Anything the operator
    deliberately typed either parses or stops the worker at startup.
    """


def _range(name: str, value: float, raw: str, lo: float | None, hi: float | None) -> None:
    if lo is not None and value < lo:
        raise ConfigError(f"{name}={raw!r} is below the minimum {lo}")
    if hi is not None and value > hi:
        raise ConfigError(f"{name}={raw!r} is above the maximum {hi}")


def _int(name: str, default: int, *, lo: int | None = None, hi: int | None = None) -> int:
    """Parse an int env var. Unset/blank → default. Malformed → ConfigError."""
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw.strip())
    except (TypeError, ValueError):
        raise ConfigError(
            f"{name}={raw.strip()!r} is not an integer (default would have been "
            f"{default}). Fix the value — it is NOT being defaulted."
        ) from None
    _range(name, value, raw.strip(), lo, hi)
    return value


def _float(name: str, default: float, *, lo: float | None = None, hi: float | None = None) -> float:
    """Parse a float env var. Unset/blank → default. Malformed → ConfigError."""
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = float(raw.strip())
    except (TypeError, ValueError):
        raise ConfigError(
            f"{name}={raw.strip()!r} is not a number (default would have been "
            f"{default}). Fix the value — it is NOT being defaulted."
        ) from None
    _range(name, value, raw.strip(), lo, hi)
    return value


_TRUE = ("1", "true", "yes", "on")
_FALSE = ("0", "false", "no", "off", "")


def _bool(name: str, default: bool = False) -> bool:
    """Parse a bool env var. Unset → default. Unrecognised → ConfigError.

    `TONEMAP_HDR=ture` used to read as False, silently disabling a guard.
    """
    v = os.environ.get(name)
    if v is None:
        return default
    s = v.strip().lower()
    if s == "":
        return default
    if s in _TRUE:
        return True
    if s in _FALSE:
        return False
    raise ConfigError(
        f"{name}={v.strip()!r} is not a boolean; use one of {_TRUE + _FALSE[:-1]}"
    )


# ── shared AI-spend guards (parsed by services/pipeline/config.py) ────────────
# The worker doesn't use these itself, but it OWNS the .env both halves read, so
# it validates them at startup: a typo in MAX_GEN_COST_PER_JOB_CENTS must stop the
# worker here, not surface as "pipeline import failed" on the first paid job.
SHARED_GUARDS: tuple[tuple[str, str, float | None, float | None], ...] = (
    ("MAX_GEN_COST_PER_JOB_CENTS", "int", 1, 1_000_000),
    ("QC_PASS_SCORE", "int", 0, 100),
    ("QC_MAX_RETRIES", "int", 0, 10),
    ("QC_CONFIDENCE_ESCALATE", "float", 0.0, 1.0),
)


def validate_shared_guards() -> list[str]:
    """Strictly parse the AI cost/QC guards. Raises ConfigError on the first bad
    one; returns a human-readable echo of what is actually in force."""
    echo = []
    for name, kind, lo, hi in SHARED_GUARDS:
        raw = os.environ.get(name)
        if raw is None or raw.strip() == "":
            continue
        value = (_int(name, 0, lo=int(lo) if lo is not None else None,
                      hi=int(hi) if hi is not None else None)
                 if kind == "int" else _float(name, 0.0, lo=lo, hi=hi))
        echo.append(f"{name}={value}")
    return echo


# The Postgres schema the Rendprop tables live in. ALL Supabase REST calls target
# it via Accept-Profile (reads) / Content-Profile (writes).
# The dedicated RendProp project (ymgqpbnjpztwjsyvceld) deployed the schema into
# the standard `public` schema — so this MUST default to `public`, matching the
# edge functions (which use the default public client) and migrations/0001_init.sql.
# Override with SUPABASE_DB_SCHEMA only if you deliberately isolate into a named schema.
DB_SCHEMA = os.environ.get("SUPABASE_DB_SCHEMA", "public")


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
    # HDR→SDR tonemap for PQ/HLG (BT.2020) sources. The chain is inserted only
    # when ffprobe says the SOURCE is HDR (never for SDR, never for untagged
    # clips) and only if the ffmpeg build has zscale+tonemap. TONEMAP_HDR=0 opts
    # out entirely (output is then re-tagged bt709 and looks washed out).
    tonemap_hdr: bool = True
    # Tone-map curve. `mobius` is the measured default: it maps out-of-range
    # highlights smoothly while leaving IN-range material alone, which is what a
    # room interior mostly is. `hable` (the old hard-coded curve) crushed
    # in-gamut content — measured on a synthetic PQ source against its SDR
    # reference: SATAVG 24.6 vs 39.4 and YAVG 73.4 vs 103.7 for hable, versus
    # 36.1 / 99.9 for mobius. See tests/test_hdr_tonemap.py.
    tonemap_curve: str = "mobius"
    # Nominal peak luminance (nits) the HDR signal is linearised against.
    tonemap_npl: float = 100.0

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
            r2_presign_expiry_s=_int("R2_PRESIGN_EXPIRY_S", 3600, lo=60, hi=604800),
            cloudflare_stream_token=os.environ.get("CLOUDFLARE_STREAM_TOKEN", ""),
            stream_poll_interval_s=_float("STREAM_POLL_INTERVAL_S", 4.0, lo=0.5, hi=60),
            stream_timeout_s=_int("STREAM_TIMEOUT_S", 900, lo=10, hi=7200),
            stream_require_ready=_bool("STREAM_REQUIRE_READY", False),
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", "ffmpeg"),
            ffprobe_bin=os.environ.get("FFPROBE_BIN", "ffprobe"),
            encode_long_edge=_int("ENCODE_LONG_EDGE", 1280, lo=240, hi=7680),
            encode_fps=_int("ENCODE_FPS", 60, lo=1, hi=240),
            encode_bitrate=os.environ.get("ENCODE_BITRATE", "14M"),
            encode_preset=os.environ.get("ENCODE_PRESET", "medium"),
            tonemap_hdr=_bool("TONEMAP_HDR", True),
            tonemap_curve=os.environ.get("TONEMAP_CURVE", "mobius").strip().lower() or "mobius",
            tonemap_npl=_float("TONEMAP_NPL", 100.0, lo=1.0, hi=10000.0),
            pipeline_dir=pipeline_dir,
            hero_seconds=_int("HERO_SECONDS", 5, lo=2, hi=12),
            render_compute_cents_per_min=_float("RENDER_COMPUTE_CENTS_PER_MIN", 0.5, lo=0.0),
            render_compute_provider=os.environ.get("RENDER_COMPUTE_PROVIDER", "modal"),
            stream_store_cents_per_min=_float("STREAM_STORE_CENTS_PER_MIN", 0.5, lo=0.0),
            poll_interval_s=_float("POLL_INTERVAL_S", 5.0, lo=0.5, hi=3600),
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


try:
    SETTINGS = Settings.from_env()
except ConfigError as e:
    # FAIL LOUD AT STARTUP. Import-time SystemExit stops the process with this
    # message instead of running on with a guard the operator thinks is set.
    raise SystemExit(
        f"FATAL: bad worker configuration: {e}\nSee services/worker/.env.example."
    ) from e
