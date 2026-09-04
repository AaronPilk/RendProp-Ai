#!/usr/bin/env python3
"""
Thin Cloudflare Stream client.

Once the tour mp4 is in R2, we register it to Stream for managed HLS/DASH +
adaptive bitrate + a player, and store the returned UID on `renders.stream_uid`
(AI-COST-MODEL.md §3: delivery is zero-egress, billed per watched minute).

Primary path = COPY-FROM-URL: hand Stream a presigned R2 GET url and it pulls the
bytes itself (no bytes route through the worker). Falls back to a direct file
upload for environments where the copy source isn't reachable.

    POST /accounts/{acct}/stream/copy      { url, meta }        → uid (ingesting)
    GET  /accounts/{acct}/stream/{uid}     → status.state, playback.hls/.dash
    POST /accounts/{acct}/stream           (multipart file)     → uid  [fallback]

Auth: `Authorization: Bearer <CLOUDFLARE_STREAM_TOKEN>`.

The worker can either block until `ready` (STREAM_REQUIRE_READY=1) or register and
move on — the UID/HLS url is valid immediately for the player, and Stream keeps
transcoding in the background. Default is non-blocking (publish fast).
"""

from __future__ import annotations

import time

import requests

from settings import SETTINGS

_API = "https://api.cloudflare.com/client/v4"


class StreamError(RuntimeError):
    """Any Cloudflare Stream API failure."""


def _base() -> str:
    return f"{_API}/accounts/{SETTINGS.cloudflare_account_id}/stream"


def _headers() -> dict:
    return {"Authorization": f"Bearer {SETTINGS.cloudflare_stream_token}"}


def _request(method: str, url: str, **kw) -> requests.Response:
    """One HTTP entry point: transport failures (DNS, timeout, reset) become
    StreamError so every caller's `except StreamError` actually catches them
    (audit F-G-06 — raw requests exceptions used to bypass the handlers)."""
    kw.setdefault("timeout", 30)
    try:
        return requests.request(method, url, **kw)
    except requests.RequestException as e:
        raise StreamError(f"Stream: network {method} {url}: {e.__class__.__name__}: {e}") from e


def _unwrap(resp: requests.Response) -> dict:
    """Cloudflare wraps everything in {success, errors, result}. Normalize it."""
    try:
        body = resp.json()
    except ValueError:
        raise StreamError(f"Stream: non-JSON HTTP {resp.status_code}: {resp.text[:500]}")
    if not resp.ok or not body.get("success", False):
        raise StreamError(f"Stream: HTTP {resp.status_code}: {body.get('errors') or body}")
    return body.get("result", {}) or {}


def copy_from_url(source_url: str, name: str | None = None, meta: dict | None = None) -> str:
    """Register a video by URL (presigned R2 GET). Returns the Stream UID."""
    payload: dict = {"url": source_url}
    md = dict(meta or {})
    if name:
        md["name"] = name
    if md:
        payload["meta"] = md
    r = _request("POST", f"{_base()}/copy", headers=_headers(), json=payload, timeout=60)
    result = _unwrap(r)
    uid = result.get("uid")
    if not uid:
        raise StreamError(f"Stream copy returned no uid: {result}")
    return uid


def direct_upload(file_path: str, name: str | None = None) -> str:
    """Fallback: push the file bytes straight to Stream (multipart). Returns UID.

    Use when the copy source isn't reachable by Cloudflare. Fine for the worker's
    ~1280p proxies; very large files should prefer the tus resumable endpoint
    (TODO) — see https://developers.cloudflare.com/stream/uploading-videos/ .
    """
    with open(file_path, "rb") as fh:
        files = {"file": (name or "tour.mp4", fh, "video/mp4")}
        r = _request("POST", _base(), headers=_headers(), files=files, timeout=SETTINGS.stream_timeout_s)
    result = _unwrap(r)
    uid = result.get("uid")
    if not uid:
        raise StreamError(f"Stream direct upload returned no uid: {result}")
    return uid


def get(uid: str) -> dict:
    """Fetch the full video object (status, playback, thumbnails, duration…)."""
    r = _request("GET", f"{_base()}/{uid}", headers=_headers(), timeout=30)
    return _unwrap(r)


def delete(uid: str) -> bool:
    """Best-effort DELETE /stream/{uid} — stop billing an orphaned copy.

    A Stream asset registered by a job that then failed keeps transcoding and is
    billed forever with nothing referencing it (audit F-G-17/F-G-21). Never
    raises: cleanup must not mask the original failure.
    """
    try:
        r = _request("DELETE", f"{_base()}/{uid}", headers=_headers(), timeout=30)
        if r.ok:
            return True
        print(f"    ⚠ could not delete orphaned Stream asset {uid}: HTTP {r.status_code}")
    except StreamError as e:
        print(f"    ⚠ could not delete orphaned Stream asset {uid}: {e}")
    return False


def playback_urls(details: dict) -> dict:
    """Pull the HLS/DASH manifest urls + thumbnail out of a Stream video object."""
    pb = details.get("playback", {}) or {}
    return {
        "hls": pb.get("hls"),
        "dash": pb.get("dash"),
        "thumbnail": details.get("thumbnail"),
        "state": (details.get("status") or {}).get("state"),
    }


def poll_ready(uid: str, timeout_s: int | None = None, interval_s: float | None = None) -> dict:
    """Block until the video is `ready` (or errors / times out). Returns details.

    Stream states: pendingupload → queued/inprogress → ready | error. The HLS url
    is usable before `ready`, so blocking here is optional (STREAM_REQUIRE_READY).
    """
    timeout_s = timeout_s or SETTINGS.stream_timeout_s
    interval_s = interval_s or SETTINGS.stream_poll_interval_s
    deadline = time.time() + timeout_s
    last: dict = {}
    while time.time() < deadline:
        last = get(uid)
        state = (last.get("status") or {}).get("state")
        if state == "ready":
            return last
        if state == "error":
            errs = (last.get("status") or {}).get("errorReasonText") or last.get("status")
            raise StreamError(f"Stream transcode failed for {uid}: {errs}")
        time.sleep(interval_s)
    raise StreamError(f"Stream {uid} not ready within {timeout_s}s (last state="
                      f"{(last.get('status') or {}).get('state')})")
