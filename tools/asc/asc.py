#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""asc.py - App Store Connect automation for Rendprop.

Dependency-free (Python 3.9+, standard library only). Runs on the owner's Mac,
where the App Store Connect API key lives. The key NEVER enters this repo and is
never printed.

Every Apple resource name, attribute name and enum value used here is backed by
Apple's own OpenAPI specification for the App Store Connect API (v4.4.1),
downloadable from:
  https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
and by the reference docs linked in comments at each call site.

Design notes
------------
* Idempotent. Every step reads current state first and only creates what is
  missing, so re-running is a no-op. `--dry-run` (or the `plan` verb) prints what
  would happen and performs no writes.
* ES256 JWTs are signed by shelling out to `openssl` so that no third-party
  crypto library is required. openssl emits a DER-encoded ECDSA signature; JWS
  needs the raw r||s form, so the DER is parsed here (see der_to_raw_signature).
* Logging prints only "METHOD /path -> status". The Authorization header, the
  key id, the issuer id and the private key are never logged.

Usage:  python3 tools/asc/asc.py --help
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal
from pathlib import Path

# ---------------------------------------------------------------------------
# Rendprop facts. These are the single source of truth for this tool.
# ---------------------------------------------------------------------------

BUNDLE_ID = "com.rendprop.app"
TEAM_ID = "5F5C5G25Y6"
APP_NAME = "Rendprop"
APP_NAME_FALLBACK = "Rendprop: AI Property Tours"
PRIMARY_LOCALE = "en-US"
VERSION_STRING = "1.0"
COPYRIGHT = "2026 Rendprop"
PLATFORM = "IOS"

# Apple category resource ids. `GET /v1/appCategories` returns these as the
# resource `id` (they are opaque strings that happen to be readable).
# https://developer.apple.com/documentation/AppStoreConnectAPI/GET-v1-appCategories
PRIMARY_CATEGORY = "BUSINESS"
SECONDARY_CATEGORY = "PHOTO_AND_VIDEO"

PRIVACY_POLICY_URL = "https://rendprop.com/privacy"
TERMS_URL = "https://rendprop.com/terms"
SUPPORT_URL = "https://rendprop.com"
MARKETING_URL = "https://rendprop.com"

# App Store Server Notifications V2 endpoint (same URL for Production and Sandbox).
# Settable through the API: PATCH /v1/apps/{id} accepts subscriptionStatusUrl,
# subscriptionStatusUrlVersion, subscriptionStatusUrlForSandbox and
# subscriptionStatusUrlVersionForSandbox (AppUpdateRequest.Data.Attributes).
# https://developer.apple.com/documentation/AppStoreConnectAPI/PATCH-v1-apps-_id_
NOTIFICATION_URL = (
    "https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify"
)
NOTIFICATION_VERSION = "V2"  # SubscriptionStatusUrlVersion enum: V1 | V2

SUBSCRIPTION_GROUP_REFERENCE_NAME = "rendprop_plans"
SUBSCRIPTION_GROUP_DISPLAY_NAME = "Rendprop Plans"

REVIEW_NOTE = (
    "Unlocks the monthly allowance shown in Settings → Plan & usage "
    "(tour renders, AI photo edits, reels, aerial intros). The paywall is "
    "Settings → Plan & usage → Upgrade plan."
)

# groupLevel: 1 is the highest-value tier. Apple uses the level to decide whether
# a switch between two products in the group is an upgrade, downgrade or crossgrade.
# https://developer.apple.com/documentation/AppStoreConnectAPI/SubscriptionCreateRequest
#
# subscriptionPeriod enum: ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS,
# SIX_MONTHS, ONE_YEAR.
SUBSCRIPTIONS = [
    {
        "productId": "com.rendprop.app.team.monthly",
        "name": "Team Monthly",
        "period": "ONE_MONTH",
        "usd": "249.00",
        "groupLevel": 1,
        "displayName": "Team Monthly",
        "description": "80 tours, 600 photo edits, 3 seats monthly.",
    },
    {
        "productId": "com.rendprop.app.team.annual",
        "name": "Team Yearly",
        "period": "ONE_YEAR",
        "usd": "2490.00",
        "groupLevel": 1,
        "displayName": "Team Yearly",
        "description": "80 tours, 600 photo edits, 3 seats monthly.",
    },
    {
        "productId": "com.rendprop.app.pro.monthly",
        "name": "Pro Monthly",
        "period": "ONE_MONTH",
        "usd": "99.00",
        "groupLevel": 2,
        "displayName": "Pro Monthly",
        "description": "25 tours, 300 photo edits, 20 reels monthly.",
    },
    {
        "productId": "com.rendprop.app.pro.annual",
        "name": "Pro Yearly",
        "period": "ONE_YEAR",
        "usd": "990.00",
        "groupLevel": 2,
        "displayName": "Pro Yearly",
        "description": "25 tours, 300 photo edits, 20 reels monthly.",
    },
    {
        "productId": "com.rendprop.app.starter.monthly",
        "name": "Starter Monthly",
        "period": "ONE_MONTH",
        "usd": "49.00",
        "groupLevel": 3,
        "displayName": "Starter Monthly",
        "description": "8 tours, 150 photo edits, 8 reels monthly.",
    },
    {
        "productId": "com.rendprop.app.starter.annual",
        "name": "Starter Yearly",
        "period": "ONE_YEAR",
        "usd": "490.00",
        "groupLevel": 3,
        "displayName": "Starter Yearly",
        "description": "8 tours, 150 photo edits, 8 reels monthly.",
    },
]

# Introductory offer applied to every product.
# SubscriptionOfferMode enum: PAY_AS_YOU_GO | PAY_UP_FRONT | FREE_TRIAL
# SubscriptionOfferDuration enum: THREE_DAYS | ONE_WEEK | TWO_WEEKS | ONE_MONTH |
#   TWO_MONTHS | THREE_MONTHS | SIX_MONTHS | ONE_YEAR
# https://developer.apple.com/documentation/AppStoreConnectAPI/SubscriptionIntroductoryOfferCreateRequest
INTRO_OFFER_MODE = "FREE_TRIAL"
INTRO_OFFER_DURATION = "ONE_WEEK"
INTRO_OFFER_PERIODS = 1

# Apple's territory id for the United States (GET /v1/territories).
USA_TERRITORY = "USA"

# US-only launch. Both the app and the subscriptions ship to the United States
# only; widening later is a deliberate decision, not a default.
# availableInNewTerritories=False stops Apple adding newly-supported storefronts
# automatically.
LAUNCH_TERRITORIES = [USA_TERRITORY]
AVAILABLE_IN_NEW_TERRITORIES = False

# In-app purchase display name / description limits, enforced by App Store Connect.
SUB_DISPLAY_NAME_MAX = 30
SUB_DESCRIPTION_MAX = 45

# App Store metadata limits.
# Name and Subtitle: 30 characters -
#   https://developer.apple.com/help/app-store-connect/reference/app-information/
# Promotional Text 170, Description 4000, Keywords 100 bytes, What's New 4000 -
#   https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
METADATA_LIMITS = {
    "name": ("characters", 30),
    "subtitle": ("characters", 30),
    "promotional_text": ("characters", 170),
    "description": ("characters", 4000),
    "keywords": ("bytes", 100),
    "release_notes": ("characters", 4000),
}

# 6.9-inch iPhone screenshots (1320 x 2868 portrait) belong to the largest
# iPhone bucket. The App Store Connect API's ScreenshotDisplayType enum has NO
# "APP_IPHONE_69" member - the largest iPhone value in the v4.4.1 spec is
# APP_IPHONE_67, and that is the set Apple's 6.9-inch sizes upload into.
#   ScreenshotDisplayType enum (verbatim, v4.4.1): APP_IPHONE_67, APP_IPHONE_61,
#   APP_IPHONE_65, APP_IPHONE_58, APP_IPHONE_55, APP_IPHONE_47, APP_IPHONE_40,
#   APP_IPHONE_35, APP_IPAD_* , APP_DESKTOP, APP_WATCH_*, APP_APPLE_TV,
#   APP_APPLE_VISION_PRO, IMESSAGE_APP_*
# https://developer.apple.com/documentation/AppStoreConnectAPI/ScreenshotDisplayType
# 1320 x 2868 is listed by Apple under "6.9-inch displays":
# https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
SCREENSHOT_DISPLAY_TYPE = "APP_IPHONE_67"
SCREENSHOT_EXPECTED_SIZE = (1320, 2868)

API_BASE = "https://api.appstoreconnect.apple.com"
JWT_AUDIENCE = "appstoreconnect-v1"  # required literal
JWT_TTL_SECONDS = 15 * 60  # Apple rejects lifetimes over 20 minutes.

DEFAULT_KEY_DIR = Path.home() / "Rendprop AI" / "_bridge" / ".asc"

REPO_ROOT = Path(__file__).resolve().parents[2]
METADATA_DIR = REPO_ROOT / "docs" / "appstore" / "metadata" / PRIMARY_LOCALE
SCREENSHOT_DIR = REPO_ROOT / "docs" / "appstore" / "screenshots" / "6.9"
IAP_SCREENSHOT = REPO_ROOT / "docs" / "appstore" / "iap-review" / "paywall.png"
# The notes Apple receives verbatim (<= 4000 chars). The .md next to it is the
# human explainer and must never be sent — it discusses the owner console.
REVIEW_NOTES_FILE = REPO_ROOT / "docs" / "appstore" / "metadata" / "en-US" / "review_notes.txt"

# App Store version states in which metadata is still editable.
EDITABLE_VERSION_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "WAITING_FOR_REVIEW",
}
EDITABLE_APPINFO_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "READY_FOR_DISTRIBUTION",
}


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class AscError(Exception):
    """A failure that should stop the run with a clear message."""


class ApiError(AscError):
    """A non-success HTTP response from App Store Connect.

    Apple's error envelope is {"errors": [{id, status, code, title, detail, ...}]}.
    https://developer.apple.com/documentation/AppStoreConnectAPI/ErrorResponse
    """

    def __init__(self, status, method, path, payload):
        self.status = status
        self.method = method
        self.path = path
        self.payload = payload
        self.errors = []
        if isinstance(payload, dict):
            self.errors = payload.get("errors") or []
        Exception.__init__(self, self._render())

    @property
    def codes(self):
        return [e.get("code", "") for e in self.errors]

    def _render(self):
        head = "%s %s failed with HTTP %s" % (self.method, self.path, self.status)
        if not self.errors:
            body = self.payload if isinstance(self.payload, str) else json.dumps(self.payload)
            return "%s\n  %s" % (head, (body or "")[:800])
        lines = [head]
        for e in self.errors:
            lines.append("  [%s] %s" % (e.get("code", "?"), e.get("title", "")))
            if e.get("detail"):
                lines.append("      %s" % e["detail"])
            src = e.get("source") or {}
            if isinstance(src, dict) and src.get("pointer"):
                lines.append("      at %s" % src["pointer"])
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# base64url, DER <-> raw ECDSA signature
# ---------------------------------------------------------------------------


def b64url_encode(raw):
    """RFC 7515 base64url: standard base64, '+/'->'-_', padding stripped."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    """Inverse of b64url_encode; re-adds the stripped padding."""
    if isinstance(text, bytes):
        text = text.decode("ascii")
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def _read_der_len(data, i):
    """Read a DER length at offset i. Returns (length, next_offset)."""
    if i >= len(data):
        raise AscError("Malformed DER signature: truncated length.")
    first = data[i]
    i += 1
    if first < 0x80:
        return first, i
    n = first & 0x7F
    if n == 0 or n > 4 or i + n > len(data):
        raise AscError("Malformed DER signature: bad long-form length.")
    value = int.from_bytes(data[i : i + n], "big")
    return value, i + n


def der_to_raw_signature(der, size=32):
    """Convert a DER ECDSA signature to the raw r||s form JWS requires.

    openssl emits SEQUENCE { INTEGER r, INTEGER s }. JWS ES256 wants r and s as
    fixed-width 32-byte big-endian values concatenated (RFC 7518 section 3.4).
    DER INTEGERs are signed, so they may carry a leading 0x00 padding byte and
    may be shorter than 32 bytes; both are normalised here.
    """
    if not isinstance(der, (bytes, bytearray)):
        raise AscError("DER signature must be bytes.")
    der = bytes(der)
    if not der or der[0] != 0x30:
        raise AscError("Malformed DER signature: expected a SEQUENCE (0x30).")
    seq_len, i = _read_der_len(der, 1)
    if i + seq_len > len(der):
        raise AscError("Malformed DER signature: SEQUENCE longer than the buffer.")
    end = i + seq_len

    ints = []
    for _ in range(2):
        if i >= end or der[i] != 0x02:
            raise AscError("Malformed DER signature: expected an INTEGER (0x02).")
        i += 1
        n, i = _read_der_len(der, i)
        if i + n > end:
            raise AscError("Malformed DER signature: INTEGER overruns the SEQUENCE.")
        raw = der[i : i + n]
        i += n
        raw = raw.lstrip(b"\x00")  # drop DER sign padding / leading zeros
        if len(raw) > size:
            raise AscError("Malformed DER signature: integer wider than %d bytes." % size)
        ints.append(raw.rjust(size, b"\x00"))
    if i != end:
        raise AscError("Malformed DER signature: trailing bytes in the SEQUENCE.")
    return ints[0] + ints[1]


def _der_encode_int(value):
    """Encode one non-negative integer as a DER INTEGER (tag, length, content)."""
    raw = value.lstrip(b"\x00")
    if not raw:
        raw = b"\x00"
    if raw[0] & 0x80:
        raw = b"\x00" + raw  # keep it positive
    return b"\x02" + bytes([len(raw)]) + raw


def raw_to_der_signature(raw):
    """Inverse of der_to_raw_signature. Used by the tests to verify with openssl."""
    if not isinstance(raw, (bytes, bytearray)) or len(raw) % 2 != 0 or not raw:
        raise AscError("Raw signature must be an even number of bytes.")
    raw = bytes(raw)
    half = len(raw) // 2
    body = _der_encode_int(raw[:half]) + _der_encode_int(raw[half:])
    if len(body) < 0x80:
        length = bytes([len(body)])
    else:
        length = b"\x81" + bytes([len(body)])
    return b"\x30" + length + body


# ---------------------------------------------------------------------------
# Credentials + JWT
# ---------------------------------------------------------------------------


class Credentials(object):
    """Key id, issuer id and private key path. None of these are ever printed."""

    def __init__(self, key_id, issuer_id, p8_path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.p8_path = Path(p8_path)


def load_credentials(key_dir=None):
    """Load credentials from the Mac-only key directory.

    Expects:
      <key_dir>/AuthKey_<KEYID>.p8   - the key id is the filename suffix
      <key_dir>/config               - a line ISSUER_ID=<uuid>
    """
    key_dir = Path(key_dir) if key_dir else DEFAULT_KEY_DIR
    if not key_dir.is_dir():
        raise AscError(
            "App Store Connect key directory not found.\n"
            "  Expected: %s\n"
            "  Create it and put AuthKey_<KEYID>.p8 plus a `config` file containing\n"
            "  ISSUER_ID=<uuid> inside. Never copy either into the repo." % key_dir
        )
    keys = sorted(key_dir.glob("AuthKey_*.p8"))
    if not keys:
        raise AscError("No AuthKey_<KEYID>.p8 found in %s" % key_dir)
    if len(keys) > 1:
        raise AscError(
            "More than one AuthKey_*.p8 in %s - leave exactly one so the key id is "
            "unambiguous." % key_dir
        )
    p8 = keys[0]
    key_id = p8.stem[len("AuthKey_") :]
    if not key_id:
        raise AscError("Could not read the key id from the filename %s" % p8.name)

    config = key_dir / "config"
    if not config.is_file():
        raise AscError("Missing %s (needs a line ISSUER_ID=<uuid>)" % config)
    issuer_id = None
    for line in config.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("ISSUER_ID="):
            issuer_id = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not issuer_id:
        raise AscError("No ISSUER_ID=<uuid> line in %s" % config)
    return Credentials(key_id, issuer_id, p8)


def sign_es256(p8_path, message):
    """Sign `message` with the .p8 EC private key, returning a raw r||s signature.

    Shells out to openssl so no third-party crypto dependency is needed.
    `openssl dgst -sha256 -sign key.p8` produces a DER signature on stdout.
    """
    try:
        proc = subprocess.Popen(
            ["openssl", "dgst", "-sha256", "-sign", str(p8_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise AscError("Could not run `openssl`: %s" % exc)
    out, err = proc.communicate(message)
    if proc.returncode != 0:
        # Deliberately does not echo the key path contents.
        raise AscError(
            "openssl could not sign with the App Store Connect private key "
            "(exit %s). Check that the .p8 file is the unmodified download from "
            "App Store Connect.\n  %s" % (proc.returncode, err.decode("utf-8", "replace").strip())
        )
    return der_to_raw_signature(out)


def build_jwt(credentials, issued_at=None, ttl=JWT_TTL_SECONDS, signer=sign_es256):
    """Build a signed ES256 JWT for the App Store Connect API.

    Header:  {"alg": "ES256", "kid": <key id>, "typ": "JWT"}
    Payload: {"iss": <issuer id>, "iat": ..., "exp": ..., "aud": "appstoreconnect-v1"}
    Apple rejects tokens whose lifetime (exp - iat) exceeds 20 minutes.
    https://developer.apple.com/documentation/AppStoreConnectAPI/generating-tokens-for-api-requests
    """
    if ttl > 20 * 60:
        raise AscError("JWT lifetime must not exceed 20 minutes.")
    now = int(time.time()) if issued_at is None else int(issued_at)
    header = {"alg": "ES256", "kid": credentials.key_id, "typ": "JWT"}
    payload = {
        "iss": credentials.issuer_id,
        "iat": now,
        "exp": now + int(ttl),
        "aud": JWT_AUDIENCE,
    }
    encode = lambda obj: b64url_encode(
        json.dumps(obj, separators=(",", ":"), sort_keys=False).encode("utf-8")
    )
    signing_input = ("%s.%s" % (encode(header), encode(payload))).encode("ascii")
    signature = signer(credentials.p8_path, signing_input)
    return "%s.%s" % (signing_input.decode("ascii"), b64url_encode(signature))


# ---------------------------------------------------------------------------
# Transport + client
# ---------------------------------------------------------------------------


def urllib_transport(method, url, headers, body, timeout=120):
    """Perform one HTTP request. Returns (status, response_headers, body_bytes).

    This is the only place that touches the network; tests inject a replacement.
    """
    request = urllib.request.Request(url=url, data=body, method=method)
    for name, value in headers.items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.getcode(), dict(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read()
    except urllib.error.URLError as exc:
        raise AscError("Network error talking to %s: %s" % (url, exc.reason))


class Client(object):
    """A thin App Store Connect JSON:API client."""

    def __init__(self, credentials=None, transport=None, verbose=True, out=None, debug=False):
        self.credentials = credentials
        self.transport = transport or urllib_transport
        self.verbose = verbose
        self.debug = debug
        self.out = out or sys.stdout
        self._token = None
        self._token_expires = 0
        self.rate_limit = None

    # -- auth ------------------------------------------------------------
    def _authorization(self):
        if self.credentials is None:
            return None
        now = time.time()
        if self._token is None or now >= self._token_expires:
            self._token = build_jwt(self.credentials, ttl=JWT_TTL_SECONDS)
            # Refresh a minute early so a long run never sends a stale token.
            self._token_expires = now + JWT_TTL_SECONDS - 60
        return "Bearer %s" % self._token

    # -- core ------------------------------------------------------------
    def request(self, method, path, body=None, params=None, expect=None):
        """Send one API request. `path` is either /v1/... or an absolute URL."""
        url = path if path.startswith("http") else API_BASE + path
        if params:
            url = "%s?%s" % (url, urllib.parse.urlencode(params, doseq=True))
        headers = {"Accept": "application/json"}
        auth = self._authorization()
        if auth:
            headers["Authorization"] = auth  # never logged
        payload = None
        if body is not None:
            payload = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        status, response_headers, raw = self.transport(method, url, headers, payload)

        limit = response_headers.get("X-Rate-Limit") or response_headers.get("x-rate-limit")
        if limit:
            self.rate_limit = limit

        # Log method + path + status only. Never the Authorization header.
        if self.verbose:
            shown = url[len(API_BASE) :] if url.startswith(API_BASE) else "<upload endpoint>"
            self.out.write("    %-6s %s -> %s\n" % (method, shown.split("?")[0], status))

        parsed = None
        if raw:
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                parsed = raw.decode("utf-8", "replace")

        allowed = expect or (200, 201, 202, 204)
        if status not in allowed:
            # Dump the exact request that failed so the next run is diagnosable.
            # `body` is the JSON:API document only - headers, and therefore the
            # bearer token, are never included.
            if self.debug and body is not None:
                self.out.write("    --- request body that failed (%s %s) ---\n"
                               % (method, url.replace(API_BASE, "")))
                for line in json.dumps(body, indent=2, sort_keys=True).splitlines():
                    self.out.write("    %s\n" % line)
                self.out.write("    --- end request body ---\n")
            if status == 429:
                raise AscError(
                    "App Store Connect rate limit hit (HTTP 429 RATE_LIMIT_EXCEEDED). "
                    "Wait and re-run - this tool is idempotent, so it will pick up "
                    "where it left off.\n  X-Rate-Limit: %s" % (self.rate_limit or "unknown")
                )
            raise ApiError(status, method, url.replace(API_BASE, ""), parsed)
        return parsed if parsed is not None else {}

    # -- helpers ---------------------------------------------------------
    def get(self, path, params=None, expect=None):
        return self.request("GET", path, params=params, expect=expect)

    def get_optional(self, path, params=None):
        """GET that treats 404 (and a null to-one relationship) as 'absent'."""
        try:
            result = self.get(path, params=params)
        except ApiError as exc:
            if exc.status == 404:
                return None
            raise
        if isinstance(result, dict) and result.get("data") is None:
            return None
        return result

    def get_all(self, path, params=None):
        """GET every page of a collection, following links.next."""
        params = dict(params or {})
        params.setdefault("limit", 200)
        items = []
        url = path
        first = True
        while url:
            page = self.get(url, params=params if first else None)
            items.extend(page.get("data") or [])
            url = (page.get("links") or {}).get("next")
            first = False
        return items

    def post(self, path, body, expect=None):
        return self.request("POST", path, body=body, expect=expect)

    def patch(self, path, body, expect=None):
        return self.request("PATCH", path, body=body, expect=expect)


# ---------------------------------------------------------------------------
# Plan (dry-run gate)
# ---------------------------------------------------------------------------

PENDING = "<pending: created by an earlier step of this run>"


class Plan(object):
    """Records intended changes; executes them unless this is a dry run."""

    def __init__(self, dry_run=False, out=None):
        self.dry_run = dry_run
        self.out = out or sys.stdout
        self.changes = 0
        self.skipped = 0

    def note(self, message):
        self.out.write("  = %s\n" % message)

    def warn(self, message):
        self.out.write("  ! %s\n" % message)

    def act(self, description, action):
        """Record `description`; run `action()` unless dry-running.

        Returns the action's result, or PENDING in a dry run (so that later
        steps can tell that an id is not yet knowable).
        """
        self.changes += 1
        if self.dry_run:
            self.out.write("  + WOULD %s\n" % description)
            return PENDING
        self.out.write("  + %s\n" % description)
        return action()

    def defer(self, description):
        """A step that cannot be planned because it depends on a pending id."""
        self.skipped += 1
        self.out.write("  . %s (after the resources above exist)\n" % description)


def is_pending(value):
    return value == PENDING or value is None


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------


def relationship(kind, identifier):
    return {"data": {"type": kind, "id": identifier}}


def attributes_of(resource):
    return (resource or {}).get("attributes") or {}


def md5_of(path):
    digest = hashlib.md5()
    with open(str(path), "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_dimensions(path):
    """Read width/height from a PNG IHDR without any imaging library."""
    with open(str(path), "rb") as handle:
        head = handle.read(33)
    if len(head) < 33 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))


def choose_price_point(points, target_usd, out=None):
    """Pick the price point matching `target_usd`, else the nearest one.

    `points` are `subscriptionPricePoints` resources; the customer-facing amount
    is attributes.customerPrice, a decimal string.
    https://developer.apple.com/documentation/AppStoreConnectAPI/SubscriptionPricePoint

    Returns (point, exact, difference). Prints a loud warning when inexact - a
    silently different price tier would be far worse than a noisy one.
    """
    out = out or sys.stdout
    target = Decimal(str(target_usd))
    priced = []
    for point in points:
        raw = attributes_of(point).get("customerPrice")
        if raw in (None, ""):
            continue
        try:
            priced.append((Decimal(str(raw)), point))
        except Exception:
            continue
    if not priced:
        raise AscError("App Store Connect returned no USD price points to choose from.")

    for value, point in priced:
        if value == target:
            return point, True, Decimal("0")

    value, point = min(priced, key=lambda item: (abs(item[0] - target), item[0]))
    difference = value - target
    out.write("\n")
    out.write("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n")
    out.write("  !! PRICE POINT WARNING\n")
    out.write("  !! Apple does not offer USD %s for this product.\n" % target)
    out.write("  !! Nearest available point: USD %s (%s%s).\n" % (value, "+" if difference > 0 else "", difference))
    out.write("  !! Check this against the pricing in docs/LAUNCH-CONTRACT.md before\n")
    out.write("  !! you submit. Set the price by hand in App Store Connect if it is wrong.\n")
    out.write("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n")
    out.write("\n")
    return point, False, difference


def check_length(field, value):
    """Enforce Apple's metadata limits. Raises AscError with a clear message."""
    if field not in METADATA_LIMITS:
        return value
    unit, limit = METADATA_LIMITS[field]
    size = len(value.encode("utf-8")) if unit == "bytes" else len(value)
    if size > limit:
        raise AscError(
            "%s is %d %s; App Store Connect allows at most %d.\n"
            "  Shorten docs/appstore/metadata/%s/%s.txt and re-run."
            % (field, size, unit, limit, PRIMARY_LOCALE, field)
        )
    return value


def read_metadata_file(name, required=True):
    """Read one metadata .txt file, trimming the trailing newline."""
    path = METADATA_DIR / ("%s.txt" % name)
    if not path.is_file():
        if required:
            raise AscError(
                "Missing metadata file %s\n"
                "  The App Store copy lives in docs/appstore/metadata/%s/." % (path, PRIMARY_LOCALE)
            )
        return None
    text = path.read_text(encoding="utf-8")
    # Keep internal blank lines (descriptions need them); drop the trailing newline.
    text = text.rstrip("\n")
    if not text.strip():
        if required:
            raise AscError("Metadata file %s is empty." % path)
        return None
    return check_length(name, text)


def load_review_contact(key_dir=None):
    """Optional review contact details, kept on the Mac beside the API key."""
    key_dir = Path(key_dir) if key_dir else DEFAULT_KEY_DIR
    path = key_dir / "review-contact.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise AscError("Could not parse %s: %s" % (path, exc))
    missing = [k for k in ("first_name", "last_name", "phone", "email") if not data.get(k)]
    if missing:
        raise AscError(
            "%s is missing: %s\n"
            "  Expected {\"first_name\",\"last_name\",\"phone\",\"email\"}." % (path, ", ".join(missing))
        )
    return data


# ---------------------------------------------------------------------------
# App lookup
# ---------------------------------------------------------------------------


def find_app(client):
    """Find the Rendprop app record by bundle id.

    The API cannot create app records - /v1/apps is GET-only in Apple's spec.
    https://developer.apple.com/documentation/AppStoreConnectAPI/GET-v1-apps
    """
    result = client.get("/v1/apps", params={"filter[bundleId]": BUNDLE_ID, "limit": 200})
    for app in result.get("data") or []:
        if attributes_of(app).get("bundleId") == BUNDLE_ID:
            return app
    return None


def require_app(client):
    app = find_app(client)
    if app is None:
        raise AscError(
            "No app record for bundle id %s.\n"
            "  The App Store Connect API cannot create app records (/v1/apps is\n"
            "  read-only). Run `asc.py app` to print the exact values to type into\n"
            "  the App Store Connect \"New App\" form, then re-run this command." % BUNDLE_ID
        )
    return app


def print_new_app_form(out):
    out.write("\n")
    out.write("The App Store Connect API cannot create an app record. Create it by hand:\n")
    out.write("  App Store Connect -> Apps -> the blue + -> New App\n\n")
    out.write("  Platforms .................. iOS  (tick iOS only)\n")
    out.write("  Name ....................... %s\n" % APP_NAME)
    out.write("      if that name is taken .. %s\n" % APP_NAME_FALLBACK)
    out.write("  Primary Language ........... English (U.S.)\n")
    out.write("  Bundle ID .................. %s\n" % BUNDLE_ID)
    out.write("      (pick the explicit App ID for %s; register it first at\n" % BUNDLE_ID)
    out.write("       Certificates, Identifiers & Profiles -> Identifiers if it is not listed)\n")
    out.write("  SKU ........................ rendprop-ios\n")
    out.write("  User Access ................ Full Access\n")
    out.write("\n")
    out.write("  Team ID (for reference) .... %s\n" % TEAM_ID)
    out.write("\nThen re-run:  python3 tools/asc/asc.py app\n")


# ---------------------------------------------------------------------------
# Subscriptions
# ---------------------------------------------------------------------------


def ensure_subscription_group(client, app_id, plan):
    """Find or create the rendprop_plans subscription group and its en-US name."""
    groups = client.get_all("/v1/apps/%s/subscriptionGroups" % app_id)
    group = None
    for candidate in groups:
        if attributes_of(candidate).get("referenceName") == SUBSCRIPTION_GROUP_REFERENCE_NAME:
            group = candidate
            break

    if group is None:
        body = {
            "data": {
                "type": "subscriptionGroups",
                "attributes": {"referenceName": SUBSCRIPTION_GROUP_REFERENCE_NAME},
                "relationships": {"app": relationship("apps", app_id)},
            }
        }
        # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionGroups
        created = plan.act(
            "create subscription group %r" % SUBSCRIPTION_GROUP_REFERENCE_NAME,
            lambda: client.post("/v1/subscriptionGroups", body),
        )
        if is_pending(created):
            return PENDING
        group_id = created["data"]["id"]
    else:
        group_id = group["id"]
        plan.note("subscription group %r exists" % SUBSCRIPTION_GROUP_REFERENCE_NAME)

    ensure_group_localization(client, group_id, plan)
    return group_id


def ensure_group_localization(client, group_id, plan):
    if is_pending(group_id):
        plan.defer("set the group display name %r" % SUBSCRIPTION_GROUP_DISPLAY_NAME)
        return
    existing = client.get_all("/v1/subscriptionGroups/%s/subscriptionGroupLocalizations" % group_id)
    for localization in existing:
        if attributes_of(localization).get("locale") == PRIMARY_LOCALE:
            if attributes_of(localization).get("name") == SUBSCRIPTION_GROUP_DISPLAY_NAME:
                plan.note("group display name is %r" % SUBSCRIPTION_GROUP_DISPLAY_NAME)
            else:
                body = {
                    "data": {
                        "type": "subscriptionGroupLocalizations",
                        "id": localization["id"],
                        "attributes": {"name": SUBSCRIPTION_GROUP_DISPLAY_NAME},
                    }
                }
                plan.act(
                    "rename group display name to %r" % SUBSCRIPTION_GROUP_DISPLAY_NAME,
                    lambda: client.patch(
                        "/v1/subscriptionGroupLocalizations/%s" % localization["id"], body
                    ),
                )
            return
    body = {
        "data": {
            "type": "subscriptionGroupLocalizations",
            "attributes": {"name": SUBSCRIPTION_GROUP_DISPLAY_NAME, "locale": PRIMARY_LOCALE},
            "relationships": {"subscriptionGroup": relationship("subscriptionGroups", group_id)},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionGroupLocalizations
    plan.act(
        "set group display name %r (%s)" % (SUBSCRIPTION_GROUP_DISPLAY_NAME, PRIMARY_LOCALE),
        lambda: client.post("/v1/subscriptionGroupLocalizations", body),
    )


def ensure_subscription(client, group_id, spec, existing_by_product, plan):
    """Create the product if missing, then converge its metadata."""
    product_id = spec["productId"]
    subscription = existing_by_product.get(product_id)

    if subscription is None:
        if is_pending(group_id):
            plan.defer("create subscription %s" % product_id)
            return PENDING
        body = {
            "data": {
                "type": "subscriptions",
                "attributes": {
                    "name": spec["name"],
                    "productId": product_id,
                    "familySharable": False,
                    "subscriptionPeriod": spec["period"],
                    "reviewNote": REVIEW_NOTE,
                    "groupLevel": spec["groupLevel"],
                },
                "relationships": {"group": relationship("subscriptionGroups", group_id)},
            }
        }
        # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptions
        try:
            created = plan.act(
                "create %s (%s, level %d)" % (product_id, spec["period"], spec["groupLevel"]),
                lambda: client.post("/v1/subscriptions", body),
            )
        except ApiError as exc:
            # A 409 here means the product id is already taken - treat as existing.
            if exc.status == 409:
                plan.note("%s already exists (HTTP 409)" % product_id)
                refreshed = client.get_all(
                    "/v1/subscriptionGroups/%s/subscriptions" % group_id,
                    params={"filter[productId]": product_id},
                )
                if not refreshed:
                    raise
                subscription = refreshed[0]
            else:
                raise
        else:
            if is_pending(created):
                return PENDING
            subscription = created["data"]
    else:
        plan.note("%s exists" % product_id)
        converge_subscription_attributes(client, subscription, spec, plan)

    return subscription["id"]


def converge_subscription_attributes(client, subscription, spec, plan):
    """PATCH only the attributes that actually differ."""
    current = attributes_of(subscription)
    wanted = {
        "name": spec["name"],
        "familySharable": False,
        "subscriptionPeriod": spec["period"],
        "reviewNote": REVIEW_NOTE,
        "groupLevel": spec["groupLevel"],
    }
    changed = {k: v for k, v in wanted.items() if current.get(k) != v}
    # subscriptionPeriod cannot be changed once a product is approved; report it
    # rather than failing the whole run.
    if not changed:
        return
    body = {"data": {"type": "subscriptions", "id": subscription["id"], "attributes": changed}}

    def apply_patch():
        try:
            return client.patch("/v1/subscriptions/%s" % subscription["id"], body)
        except ApiError as exc:
            plan.warn(
                "could not update %s (%s). Fix it in App Store Connect -> "
                "Monetization -> Subscriptions." % (spec["productId"], ", ".join(exc.codes) or exc.status)
            )
            return None

    plan.act("update %s: %s" % (spec["productId"], ", ".join(sorted(changed))), apply_patch)


def ensure_subscription_localization(client, subscription_id, spec, plan):
    if is_pending(subscription_id):
        plan.defer("localize %s" % spec["productId"])
        return
    display_name = check_sub_text(spec["displayName"], SUB_DISPLAY_NAME_MAX, "display name", spec)
    description = check_sub_text(spec["description"], SUB_DESCRIPTION_MAX, "description", spec)

    existing = client.get_all("/v1/subscriptions/%s/subscriptionLocalizations" % subscription_id)
    for localization in existing:
        attrs = attributes_of(localization)
        if attrs.get("locale") != PRIMARY_LOCALE:
            continue
        if attrs.get("name") == display_name and attrs.get("description") == description:
            plan.note("%s localization is current" % spec["productId"])
            return
        body = {
            "data": {
                "type": "subscriptionLocalizations",
                "id": localization["id"],
                "attributes": {"name": display_name, "description": description},
            }
        }
        plan.act(
            "update %s localization" % spec["productId"],
            lambda: client.patch("/v1/subscriptionLocalizations/%s" % localization["id"], body),
        )
        return

    body = {
        "data": {
            "type": "subscriptionLocalizations",
            "attributes": {
                "name": display_name,
                "locale": PRIMARY_LOCALE,
                "description": description,
            },
            "relationships": {"subscription": relationship("subscriptions", subscription_id)},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionLocalizations
    plan.act(
        "localize %s as %r" % (spec["productId"], display_name),
        lambda: client.post("/v1/subscriptionLocalizations", body),
    )


def check_sub_text(value, limit, label, spec):
    if len(value) > limit:
        raise AscError(
            "%s %s is %d characters; App Store Connect allows %d.\n  %r"
            % (spec["productId"], label, len(value), limit, value)
        )
    return value


def price_point_territory(point):
    """Best-effort territory for a price point.

    Prefers the `territory` relationship (populated by include=territory). Falls
    back to decoding the resource id, which App Store Connect builds as base64url
    of {"s": <subscription id>, "t": <territory>, "p": <opaque tier id>}.

    Confirmed against a live response: the USA point for USD 249.00 on
    subscription 6808983164 is {"s":"6808983164","t":"USA","p":"10605"} - so `p`
    is Apple's internal price-point tier, NOT the amount in minor units. Only `t`
    is read here. The id is opaque by contract, so a decode failure is not an
    error; it just means this cross-check cannot be made for that point.
    """
    related = (((point or {}).get("relationships") or {}).get("territory") or {}).get("data")
    if isinstance(related, dict) and related.get("id"):
        return related["id"]
    try:
        decoded = json.loads(b64url_decode(point["id"]).decode("utf-8"))
    except Exception:
        return None
    value = decoded.get("t")
    return value if isinstance(value, str) else None


def usa_price_points(points, out=None):
    """Keep only the USA price points, and say so if anything else showed up.

    filter[territory]=USA should already guarantee this. The check exists because
    a price point from the wrong territory is numerically plausible - 249.00 MXN
    looks exactly like 249.00 USD to a price comparison - and App Store Connect
    rejects the resulting request with a RELATIONSHIP.INVALID error that does not
    explain itself.
    """
    out = out or sys.stdout
    keep, foreign = [], set()
    for point in points:
        territory = price_point_territory(point)
        if territory is None or territory == USA_TERRITORY:
            keep.append(point)   # unknown territory: trust filter[territory]
        else:
            foreign.add(territory)
    if foreign:
        out.write("  ! ignored %d price point(s) from %s; only %s points are used\n"
                  % (len(points) - len(keep), ", ".join(sorted(foreign)), USA_TERRITORY))
    if not keep:
        raise AscError(
            "No %s price points came back for this subscription. Check that the "
            "Paid Applications agreement is active - Apple offers no price points "
            "until it is." % USA_TERRITORY
        )
    return keep


def priced_territories(prices):
    """Territory ids that already have a price, from a prices listing."""
    found = set()
    for price in prices:
        data = (((price.get("relationships") or {}).get("territory") or {}).get("data") or {})
        if data.get("id"):
            found.add(data["id"])
    return found


def price_other_territories(client, subscription_id, spec, usa_point, missing, plan):
    """Price the non-USA territories from the USA point's equalizations.

    Only reachable if a product ends up available outside the launch territories.
    Apple calls the matching points in other territories "equalizations" of a
    price point, which is exactly the mapping needed here.
    https://developer.apple.com/documentation/AppStoreConnectAPI/GET-v1-subscriptionPricePoints-_id_-equalizations
    """
    equalizations = client.get_all(
        "/v1/subscriptionPricePoints/%s/equalizations" % usa_point["id"],
        params={"filter[territory]": ",".join(sorted(missing)),
                "include": "territory", "limit": 8000},
    )
    by_territory = {}
    for point in equalizations:
        territory = price_point_territory(point)
        if territory:
            by_territory[territory] = point

    unmatched = sorted(t for t in missing if t not in by_territory)
    if unmatched:
        plan.warn("no equalized price point for %d territor%s (%s%s)"
                  % (len(unmatched), "y" if len(unmatched) == 1 else "ies",
                     ", ".join(unmatched[:8]), "..." if len(unmatched) > 8 else ""))

    for territory in sorted(by_territory):
        point = by_territory[territory]
        body = {
            "data": {
                "type": "subscriptionPrices",
                "relationships": {
                    "subscription": relationship("subscriptions", subscription_id),
                    "territory": relationship("territories", territory),
                    "subscriptionPricePoint": relationship(
                        "subscriptionPricePoints", point["id"]),
                },
            }
        }
        plan.act(
            "price %s in %s at %s"
            % (spec["productId"], territory, attributes_of(point).get("customerPrice")),
            lambda body=body: client.post("/v1/subscriptionPrices", body),
        )


def ensure_subscription_price(client, subscription_id, spec, territories, plan):
    """Price the product in every territory it is available in.

    `territories` comes from ensure_subscription_availability, which must run
    first - App Store Connect rejects a price for a product that has no
    availability yet.
    """
    if is_pending(subscription_id):
        plan.defer("price %s at USD %s" % (spec["productId"], spec["usd"]))
        return
    territories = list(territories or LAUNCH_TERRITORIES)
    prices = client.get_all(
        "/v1/subscriptions/%s/prices" % subscription_id,
        params={"include": "subscriptionPricePoint,territory", "limit": 200},
    )
    already = priced_territories(prices)
    missing = [t for t in territories if t not in already]
    if prices and not missing:
        plan.note("%s is priced in all %d territor%s it sells in"
                  % (spec["productId"], len(territories),
                     "y" if len(territories) == 1 else "ies"))
        return
    if prices and USA_TERRITORY in already:
        # The USA price is set but other territories are not. This only happens
        # if availability was widened beyond the launch territories.
        plan.warn("%s is priced in %d territor%s but available in %d - filling the gaps"
                  % (spec["productId"], len(already),
                     "y" if len(already) == 1 else "ies", len(territories)))

    # List the USD price points offered for THIS subscription, then match the
    # target amount exactly, or take the nearest with a loud warning.
    #
    # include=territory populates relationships.territory so the chosen point can
    # be proved to be a USA one before it is used. limit=8000 is the maximum the
    # spec allows and fetches Apple's ~800 USA points in a single request instead
    # of paging four times.
    # https://developer.apple.com/documentation/AppStoreConnectAPI/GET-v1-subscriptions-_id_-pricePoints
    points = client.get_all(
        "/v1/subscriptions/%s/pricePoints" % subscription_id,
        params={
            "filter[territory]": USA_TERRITORY,
            "include": "territory",
            "limit": 8000,
        },
    )
    points = usa_price_points(points, out=plan.out)
    point, exact, _difference = choose_price_point(points, spec["usd"], out=plan.out)
    amount = attributes_of(point).get("customerPrice")

    body = {
        "data": {
            "type": "subscriptionPrices",
            # No attributes. This is the product's FIRST price, which is what
            # Apple's own UI creates: no startDate (so it applies immediately)
            # and no preserveCurrentPrice (there is no current price to preserve,
            # and no subscribers to preserve it for). Both attributes are
            # optional in SubscriptionPriceCreateRequest.
            #
            # The live 409 on this call turned out to be ORDER, not shape: the
            # product had no subscriptionAvailability yet. The identical request
            # succeeded once availability existed. Availability is now created
            # first, and the attributes stay omitted to match Apple's own UI.
            "relationships": {
                "subscription": relationship("subscriptions", subscription_id),
                # The endpoint is documented as "Schedule a subscription price
                # change for a specific territory", so the territory is sent
                # explicitly alongside the price point rather than left to be
                # inferred from the point's opaque id.
                "territory": relationship("territories", USA_TERRITORY),
                "subscriptionPricePoint": relationship("subscriptionPricePoints", point["id"]),
            },
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionPrices
    if USA_TERRITORY in missing:
        plan.act(
            "price %s at USD %s%s" % (spec["productId"], amount,
                                      "" if exact else "  <-- NOT the requested %s" % spec["usd"]),
            lambda: client.post("/v1/subscriptionPrices", body),
        )

    # US-only launch means one price is the whole schedule. This only does
    # anything if the product turned out to be available more widely.
    others = [t for t in missing if t != USA_TERRITORY]
    if others and not plan.dry_run:
        price_other_territories(client, subscription_id, spec, point, others, plan)
    elif others:
        plan.defer("price %s in %d further territor%s from the USA point's equalizations"
                   % (spec["productId"], len(others), "y" if len(others) == 1 else "ies"))


def availability_body(subscription_id, territories):
    return {
        "data": {
            "type": "subscriptionAvailabilities",
            "attributes": {"availableInNewTerritories": AVAILABLE_IN_NEW_TERRITORIES},
            "relationships": {
                "subscription": relationship("subscriptions", subscription_id),
                "availableTerritories": {
                    "data": [{"type": "territories", "id": t} for t in territories]
                },
            },
        }
    }


def ensure_subscription_availability(client, subscription_id, spec, plan):
    """Make the product available in the launch territories (US only).

    Availability must exist BEFORE a price can be created: on the live run, a
    price POST against a product with no availability failed with
    ENTITY_ERROR.RELATIONSHIP.INVALID, and the identical request succeeded once
    availability was in place.

    Returns the territory ids the product is actually available in, so pricing
    can cover exactly those and never leave a product half-priced.
    """
    if is_pending(subscription_id):
        plan.defer("make %s available in %s" % (spec["productId"], ", ".join(LAUNCH_TERRITORIES)))
        return list(LAUNCH_TERRITORIES)

    wanted = list(LAUNCH_TERRITORIES)
    # A subscription with no availability yet returns 404 here, not an empty
    # object - get_optional turns both into None.
    current = client.get_optional("/v1/subscriptions/%s/subscriptionAvailability" % subscription_id)

    if not (current and (current.get("data") or {}).get("id")):
        # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionAvailabilities
        plan.act(
            "make %s available in %s only" % (spec["productId"], ", ".join(wanted)),
            lambda: client.post("/v1/subscriptionAvailabilities",
                                availability_body(subscription_id, wanted)),
        )
        return wanted

    availability_id = current["data"]["id"]
    listed = sorted(t["id"] for t in client.get_all(
        "/v1/subscriptionAvailabilities/%s/availableTerritories" % availability_id))
    if listed == sorted(wanted):
        plan.note("%s is available in %s only" % (spec["productId"], ", ".join(wanted)))
        return listed

    # The set is wrong. There is no PATCH or DELETE for subscriptionAvailabilities
    # in Apple's spec, so the only thing to try is another POST, in case it
    # behaves as an upsert. If it does not, say so loudly and carry on - a wrong
    # territory list is a business problem for a human, not a reason to abort.
    def replace():
        try:
            client.post("/v1/subscriptionAvailabilities",
                        availability_body(subscription_id, wanted))
            return wanted
        except ApiError as exc:
            plan.warn(
                "%s is available in %d territories, but this launch is %s only.\n"
                "      Re-POSTing the availability failed (%s), so the API cannot\n"
                "      narrow an availability that already exists.\n"
                "      FIX THIS BY HAND before selling: App Store Connect ->\n"
                "      Monetization -> Subscriptions -> %s -> Availability ->\n"
                "      deselect everything except the United States.\n"
                "      Until then this product is priced only in %s but listed in\n"
                "      %d territories."
                % (spec["productId"], len(listed), ", ".join(wanted),
                   ", ".join(exc.codes) or exc.status, spec["productId"],
                   ", ".join(wanted), len(listed))
            )
            return None

    outcome = plan.act(
        "narrow %s availability from %d territories to %s"
        % (spec["productId"], len(listed), ", ".join(wanted)),
        replace,
    )
    if plan.dry_run:
        return wanted
    # If the replace failed, price what the product is actually available in.
    return wanted if outcome == wanted else listed


def ensure_introductory_offer(client, subscription_id, spec, plan, territories=None):
    """Add the 1-week free trial in every territory the product sells in.

    Apple requires the `territory` relationship on this request — the live run
    without it failed with ENTITY_ERROR.RELATIONSHIP.REQUIRED ("You must provide
    a value for the relationship 'territory'"). So one offer is created PER
    territory the product is available in (USA only at launch), and territories
    that already carry an offer are left alone.
    https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionIntroductoryOffers
    """
    if is_pending(subscription_id):
        plan.defer("add a 1-week free trial to %s" % spec["productId"])
        return
    wanted = list(territories or LAUNCH_TERRITORIES)
    offers = client.get_all(
        "/v1/subscriptions/%s/introductoryOffers" % subscription_id,
        params={"include": "territory", "limit": 200},
    )
    covered = set()
    for offer in offers:
        rel = ((offer.get("relationships") or {}).get("territory") or {}).get("data") or {}
        if rel.get("id"):
            covered.add(rel["id"])
    if offers and not covered:
        # An offer with no territory relationship in the response applies
        # everywhere; nothing to add.
        plan.note("%s already has an introductory offer" % spec["productId"])
        return
    missing = [t for t in wanted if t not in covered]
    if not missing:
        plan.note("%s already has a free trial in every launch territory" % spec["productId"])
        return
    for territory_id in missing:
        body = {
            "data": {
                "type": "subscriptionIntroductoryOffers",
                "attributes": {
                    "duration": INTRO_OFFER_DURATION,
                    "offerMode": INTRO_OFFER_MODE,
                    "numberOfPeriods": INTRO_OFFER_PERIODS,
                },
                "relationships": {
                    "subscription": relationship("subscriptions", subscription_id),
                    "territory": relationship("territories", territory_id),
                },
            }
        }
        plan.act(
            "add a 1-week free trial to %s in %s" % (spec["productId"], territory_id),
            lambda body=body: client.post("/v1/subscriptionIntroductoryOffers", body),
        )


def ensure_notification_urls(client, app, plan):
    """Point App Store Server Notifications V2 at the Supabase function.

    Settable through the API - AppUpdateRequest exposes subscriptionStatusUrl,
    subscriptionStatusUrlVersion, subscriptionStatusUrlForSandbox and
    subscriptionStatusUrlVersionForSandbox.
    https://developer.apple.com/documentation/AppStoreConnectAPI/PATCH-v1-apps-_id_
    """
    current = attributes_of(app)
    wanted = {
        "subscriptionStatusUrl": NOTIFICATION_URL,
        "subscriptionStatusUrlVersion": NOTIFICATION_VERSION,
        "subscriptionStatusUrlForSandbox": NOTIFICATION_URL,
        "subscriptionStatusUrlVersionForSandbox": NOTIFICATION_VERSION,
    }
    changed = {k: v for k, v in wanted.items() if current.get(k) != v}
    if not changed:
        plan.note("App Store Server Notifications V2 URLs are set (production + sandbox)")
        return
    body = {"data": {"type": "apps", "id": app["id"], "attributes": changed}}

    def apply_patch():
        try:
            return client.patch("/v1/apps/%s" % app["id"], body)
        except ApiError as exc:
            plan.warn(
                "could not set the notification URLs (%s). Set them by hand:\n"
                "      App Store Connect -> your app -> App Information ->\n"
                "      App Store Server Notifications -> Production Server URL and\n"
                "      Sandbox Server URL, both Version 2, both:\n      %s"
                % (", ".join(exc.codes) or exc.status, NOTIFICATION_URL)
            )
            return None

    plan.act(
        "set App Store Server Notifications V2 URLs (production + sandbox)",
        apply_patch,
    )


def cmd_subscriptions(client, args, out):
    plan = Plan(dry_run=args.dry_run, out=out)
    app = require_app(client)
    out.write("App: %s (id %s)\n" % (attributes_of(app).get("name"), app["id"]))

    out.write("\nApp Store Server Notifications\n")
    ensure_notification_urls(client, app, plan)

    out.write("\nSubscription group\n")
    group_id = ensure_subscription_group(client, app["id"], plan)

    existing_by_product = {}
    if not is_pending(group_id):
        for subscription in client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group_id):
            existing_by_product[attributes_of(subscription).get("productId")] = subscription

    out.write("\nLaunch territories: %s only (availableInNewTerritories=%s)\n"
              % (", ".join(LAUNCH_TERRITORIES), str(AVAILABLE_IN_NEW_TERRITORIES).lower()))

    for spec in SUBSCRIPTIONS:
        out.write("\n%s\n" % spec["productId"])
        subscription_id = ensure_subscription(client, group_id, spec, existing_by_product, plan)
        ensure_subscription_localization(client, subscription_id, spec, plan)
        # Availability MUST come before pricing: App Store Connect rejects a
        # price for a product that has no availability yet.
        territories = ensure_subscription_availability(client, subscription_id, spec, plan)
        ensure_subscription_price(client, subscription_id, spec, territories, plan)
        ensure_introductory_offer(client, subscription_id, spec, plan, territories)

    summarise(plan, out, "subscriptions")
    return 0


# ---------------------------------------------------------------------------
# App metadata
# ---------------------------------------------------------------------------


def editable_app_info(client, app_id):
    """Return the appInfo whose metadata can still be edited."""
    infos = client.get_all("/v1/apps/%s/appInfos" % app_id)
    if not infos:
        raise AscError("The app has no appInfos resource - that should not happen.")
    for info in infos:
        if attributes_of(info).get("state") in EDITABLE_APPINFO_STATES:
            return info
    return infos[0]


def ensure_categories(client, app_info, plan):
    """Set the primary and secondary App Store categories.

    Category ids come from GET /v1/appCategories (there is no create endpoint).
    https://developer.apple.com/documentation/AppStoreConnectAPI/PATCH-v1-appInfos-_id_
    """
    relationships = (app_info.get("relationships") or {})
    current_primary = ((relationships.get("primaryCategory") or {}).get("data") or {}).get("id")
    current_secondary = ((relationships.get("secondaryCategory") or {}).get("data") or {}).get("id")

    if current_primary == PRIMARY_CATEGORY and current_secondary == SECONDARY_CATEGORY:
        plan.note("categories are %s / %s" % (PRIMARY_CATEGORY, SECONDARY_CATEGORY))
        return

    available = {c["id"] for c in client.get_all(
        "/v1/appCategories", params={"filter[platforms]": PLATFORM, "exists[parent]": "false"}
    )}
    for wanted in (PRIMARY_CATEGORY, SECONDARY_CATEGORY):
        if available and wanted not in available:
            raise AscError(
                "App Store category %r is not offered for iOS. Available top-level "
                "categories: %s" % (wanted, ", ".join(sorted(available)))
            )

    body = {
        "data": {
            "type": "appInfos",
            "id": app_info["id"],
            "relationships": {
                "primaryCategory": relationship("appCategories", PRIMARY_CATEGORY),
                "secondaryCategory": relationship("appCategories", SECONDARY_CATEGORY),
            },
        }
    }
    plan.act(
        "set categories to %s / %s" % (PRIMARY_CATEGORY, SECONDARY_CATEGORY),
        lambda: client.patch("/v1/appInfos/%s" % app_info["id"], body),
    )


def ensure_age_rating(client, app_info, plan):
    """Declare that nothing applies, which yields a 4+ rating.

    Attribute names and enum values are from AgeRatingDeclarationUpdateRequest in
    the v4.4.1 spec. The enum for every content field is
    NONE | INFREQUENT_OR_MILD | FREQUENT_OR_INTENSE | INFREQUENT | FREQUENT.
    https://developer.apple.com/documentation/AppStoreConnectAPI/PATCH-v1-ageRatingDeclarations-_id_
    """
    declaration = client.get_optional("/v1/appInfos/%s/ageRatingDeclaration" % app_info["id"])
    if not declaration or not (declaration.get("data") or {}).get("id"):
        plan.warn("no ageRatingDeclaration on this app info; set the rating in the UI")
        return
    declaration_id = declaration["data"]["id"]

    none_fields = [
        "alcoholTobaccoOrDrugUseOrReferences",
        "contests",
        "gamblingSimulated",
        "gunsOrOtherWeapons",
        "medicalOrTreatmentInformation",
        "profanityOrCrudeHumor",
        "sexualContentGraphicAndNudity",
        "sexualContentOrNudity",
        "horrorOrFearThemes",
        "matureOrSuggestiveThemes",
        "violenceCartoonOrFantasy",
        "violenceRealisticProlongedGraphicOrSadistic",
        "violenceRealistic",
    ]
    false_fields = [
        "advertising",
        "gambling",
        "healthOrWellnessTopics",
        "lootBox",
        "messagingAndChat",
        "parentalControls",
        "socialMedia",
        "unrestrictedWebAccess",
        "userGeneratedContent",
    ]
    wanted = {}
    for field in none_fields:
        wanted[field] = "NONE"
    for field in false_fields:
        wanted[field] = False
    wanted["ageRatingOverride"] = "NONE"
    wanted["koreaAgeRatingOverride"] = "NONE"

    current = attributes_of(declaration.get("data"))
    changed = {k: v for k, v in wanted.items() if current.get(k) != v}
    if not changed:
        plan.note("age rating declaration already says nothing applies (4+)")
        return

    body = {
        "data": {"type": "ageRatingDeclarations", "id": declaration_id, "attributes": changed}
    }

    def apply_patch():
        try:
            return client.patch("/v1/ageRatingDeclarations/%s" % declaration_id, body)
        except ApiError as exc:
            plan.warn(
                "could not set the age rating (%s). Set it by hand: App Store Connect\n"
                "      -> your app -> App Information -> Age Rating -> Edit -> answer\n"
                "      None/No to everything -> 4+."
                % (", ".join(exc.codes) or exc.status)
            )
            return None

    plan.act("declare age rating (nothing applies -> 4+), %d fields" % len(changed), apply_patch)


def ensure_app_info_localization(client, app_info, name, subtitle, plan):
    """Set the App Store name, subtitle and privacy policy URL."""
    localizations = client.get_all("/v1/appInfos/%s/appInfoLocalizations" % app_info["id"])
    wanted = {
        "name": name,
        "subtitle": subtitle,
        "privacyPolicyUrl": PRIVACY_POLICY_URL,
    }
    for localization in localizations:
        attrs = attributes_of(localization)
        if attrs.get("locale") != PRIMARY_LOCALE:
            continue
        changed = {k: v for k, v in wanted.items() if attrs.get(k) != v}
        if not changed:
            plan.note("app name/subtitle/privacy URL are current")
            return
        body = {
            "data": {
                "type": "appInfoLocalizations",
                "id": localization["id"],
                "attributes": changed,
            }
        }
        plan.act(
            "update app info (%s)" % ", ".join(sorted(changed)),
            lambda: client.patch("/v1/appInfoLocalizations/%s" % localization["id"], body),
        )
        return

    body = {
        "data": {
            "type": "appInfoLocalizations",
            "attributes": dict(wanted, locale=PRIMARY_LOCALE),
            "relationships": {"appInfo": relationship("appInfos", app_info["id"])},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appInfoLocalizations
    plan.act("create the %s app info localization" % PRIMARY_LOCALE,
             lambda: client.post("/v1/appInfoLocalizations", body))


def ensure_app_availability_usa(client, app_id, plan):
    """Restrict the app itself to the launch territories (US only).

    POST /v2/appAvailabilities uses JSON:API inline creates: the
    territoryAvailabilities relationship references placeholder ids that are
    defined in the top-level `included` array.
    https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v2-appAvailabilities
    """
    wanted = sorted(LAUNCH_TERRITORIES)
    current = client.get_optional("/v1/apps/%s/appAvailabilityV2" % app_id)
    if current and (current.get("data") or {}).get("id"):
        availability_id = current["data"]["id"]
        listed = client.get_all(
            "/v2/appAvailabilities/%s/territoryAvailabilities" % availability_id,
            params={"include": "territory", "limit": 200},
        )
        available = sorted(
            ((((t.get("relationships") or {}).get("territory") or {}).get("data") or {}).get("id"))
            for t in listed if attributes_of(t).get("available")
        )
        available = [t for t in available if t]
        if available == wanted:
            plan.note("the app itself is available in %s only" % ", ".join(wanted))
            return
        plan.note("the app is currently available in %d territor%s"
                  % (len(available), "y" if len(available) == 1 else "ies"))

    body = {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": AVAILABLE_IN_NEW_TERRITORIES},
            "relationships": {
                "app": relationship("apps", app_id),
                "territoryAvailabilities": {
                    "data": [{"type": "territoryAvailabilities", "id": t} for t in wanted]
                },
            },
        },
        "included": [
            {
                "type": "territoryAvailabilities",
                "id": t,
                "attributes": {"available": True},
                "relationships": {"territory": relationship("territories", t)},
            }
            for t in wanted
        ],
    }

    def apply_availability():
        try:
            return client.post("/v2/appAvailabilities", body)
        except ApiError as exc:
            plan.warn(
                "could not set the app's territory availability (%s).\n"
                "      Set it by hand: App Store Connect -> your app -> Pricing and\n"
                "      Availability -> Availability -> Edit -> United States only."
                % (", ".join(exc.codes) or exc.status)
            )
            return None

    plan.act("make the app available in %s only" % ", ".join(wanted), apply_availability)


def find_editable_version(client, app_id):
    """Find the 1.0 iOS App Store version that is still editable."""
    versions = client.get_all(
        "/v1/apps/%s/appStoreVersions" % app_id,
        params={"filter[platform]": PLATFORM, "limit": 200},
    )
    for version in versions:
        attrs = attributes_of(version)
        if attrs.get("versionString") != VERSION_STRING:
            continue
        state = attrs.get("appVersionState") or attrs.get("appStoreState")
        if state in EDITABLE_VERSION_STATES:
            return version
    for version in versions:
        state = attributes_of(version).get("appVersionState") or attributes_of(version).get("appStoreState")
        if state in EDITABLE_VERSION_STATES:
            return version
    return None


def ensure_app_store_version(client, app_id, plan, copyright_text=None):
    copyright_text = copyright_text or COPYRIGHT
    version = find_editable_version(client, app_id)
    if version is not None:
        attrs = attributes_of(version)
        plan.note("App Store version %s exists (%s)"
                  % (attrs.get("versionString"),
                     attrs.get("appVersionState") or attrs.get("appStoreState")))
        if attrs.get("copyright") != copyright_text:
            body = {
                "data": {
                    "type": "appStoreVersions",
                    "id": version["id"],
                    "attributes": {"copyright": copyright_text},
                }
            }
            plan.act("set copyright to %r" % copyright_text,
                     lambda: client.patch("/v1/appStoreVersions/%s" % version["id"], body))
        return version["id"]

    body = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": PLATFORM,
                "versionString": VERSION_STRING,
                "copyright": copyright_text,
                # releaseType MANUAL: the owner presses "Release this version"
                # after approval, rather than Apple releasing it automatically.
                "releaseType": "MANUAL",
            },
            "relationships": {"app": relationship("apps", app_id)},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appStoreVersions
    created = plan.act(
        "create App Store version %s for %s" % (VERSION_STRING, PLATFORM),
        lambda: client.post("/v1/appStoreVersions", body),
    )
    if is_pending(created):
        return PENDING
    return created["data"]["id"]


def ensure_version_localization(client, version_id, values, plan, announce=True):
    """Find or create the en-US version localization, converging `values`.

    Called with an empty `values` by the screenshot and review commands, which
    only need the localization's id.
    """
    if is_pending(version_id):
        if announce:
            plan.defer("write the %s listing copy" % PRIMARY_LOCALE)
        return PENDING
    localizations = client.get_all(
        "/v1/appStoreVersions/%s/appStoreVersionLocalizations" % version_id
    )
    for localization in localizations:
        attrs = attributes_of(localization)
        if attrs.get("locale") != PRIMARY_LOCALE:
            continue
        changed = {k: v for k, v in values.items() if attrs.get(k) != v}
        if not changed:
            if announce:
                plan.note("listing copy is current")
            return localization["id"]
        body = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": localization["id"],
                "attributes": changed,
            }
        }
        plan.act(
            "update listing copy (%s)" % ", ".join(sorted(changed)),
            lambda: client.patch(
                "/v1/appStoreVersionLocalizations/%s" % localization["id"], body
            ),
        )
        return localization["id"]

    body = {
        "data": {
            "type": "appStoreVersionLocalizations",
            "attributes": dict(values, locale=PRIMARY_LOCALE),
            "relationships": {"appStoreVersion": relationship("appStoreVersions", version_id)},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appStoreVersionLocalizations
    created = plan.act(
        "write the %s listing copy" % PRIMARY_LOCALE,
        lambda: client.post("/v1/appStoreVersionLocalizations", body),
    )
    if is_pending(created):
        return PENDING
    return created["data"]["id"]


def read_listing_metadata():
    """Read and validate every metadata file. Fails loudly on any problem."""
    if not METADATA_DIR.is_dir():
        raise AscError(
            "No metadata directory at %s\n"
            "  The App Store copy lives in docs/appstore/metadata/%s/ as one .txt\n"
            "  file per field: name, subtitle, description, keywords,\n"
            "  promotional_text, release_notes, support_url, marketing_url,\n"
            "  privacy_url." % (METADATA_DIR, PRIMARY_LOCALE)
        )
    values = {
        "name": read_metadata_file("name"),
        "subtitle": read_metadata_file("subtitle"),
        "description": read_metadata_file("description"),
        "keywords": read_metadata_file("keywords"),
        "promotional_text": read_metadata_file("promotional_text"),
        "release_notes": read_metadata_file("release_notes"),
        "support_url": read_metadata_file("support_url"),
        "marketing_url": read_metadata_file("marketing_url", required=False) or MARKETING_URL,
        "privacy_url": read_metadata_file("privacy_url", required=False) or PRIVACY_POLICY_URL,
        # Optional: if docs/appstore/metadata/en-US/copyright.txt exists it wins,
        # so the listing copy stays the single source of truth for the wording.
        "copyright": read_metadata_file("copyright", required=False) or COPYRIGHT,
    }
    for field in ("support_url", "marketing_url", "privacy_url"):
        if not values[field].startswith("https://"):
            raise AscError("%s must be an https:// URL, got %r" % (field, values[field]))
    if values["name"] not in (APP_NAME, APP_NAME_FALLBACK):
        # Not fatal - the owner may have had to pick another name - but say so.
        sys.stdout.write(
            "  ! name.txt says %r, which is neither %r nor the agreed fallback %r\n"
            % (values["name"], APP_NAME, APP_NAME_FALLBACK)
        )
    return values


def cmd_metadata(client, args, out):
    plan = Plan(dry_run=args.dry_run, out=out)
    values = read_listing_metadata()
    out.write("Metadata files validated against Apple's limits:\n")
    for field, (unit, limit) in sorted(METADATA_LIMITS.items()):
        text = values.get(field)
        if text is None:
            continue
        size = len(text.encode("utf-8")) if unit == "bytes" else len(text)
        out.write("  %-18s %5d / %-5d %s\n" % (field, size, limit, unit))

    app = require_app(client)
    out.write("\nApp: %s (id %s)\n" % (attributes_of(app).get("name"), app["id"]))

    out.write("\nApp information\n")
    app_info = editable_app_info(client, app["id"])
    ensure_app_info_localization(client, app_info, values["name"], values["subtitle"], plan)
    ensure_categories(client, app_info, plan)
    ensure_age_rating(client, app_info, plan)

    out.write("\nAvailability\n")
    ensure_app_availability_usa(client, app["id"], plan)

    out.write("\nVersion %s\n" % VERSION_STRING)
    version_id = ensure_app_store_version(client, app["id"], plan, values["copyright"])
    ensure_version_localization(
        client,
        version_id,
        {
            "description": values["description"],
            "keywords": values["keywords"],
            "promotionalText": values["promotional_text"],
            "whatsNew": values["release_notes"],
            "supportUrl": values["support_url"],
            "marketingUrl": values["marketing_url"],
        },
        plan,
    )

    summarise(plan, out, "metadata")
    return 0


# ---------------------------------------------------------------------------
# Asset upload (screenshots and the IAP review screenshot)
# ---------------------------------------------------------------------------


def run_upload_operations(client, operations, data, out):
    """Execute the uploadOperations Apple returns for a reserved asset.

    Each operation carries its own absolute url, method, offset, length and
    requestHeaders. The Authorization header must NOT be sent to these hosts.
    https://developer.apple.com/documentation/AppStoreConnectAPI/UploadOperation
    """
    for index, operation in enumerate(operations or [], start=1):
        offset = operation.get("offset") or 0
        length = operation.get("length") or 0
        chunk = data[offset : offset + length]
        headers = {}
        for header in operation.get("requestHeaders") or []:
            if header.get("name"):
                headers[header["name"]] = header.get("value", "")
        status, _headers, body = client.transport(
            operation.get("method", "PUT"), operation["url"], headers, chunk
        )
        out.write("      chunk %d/%d (%d bytes) -> %s\n"
                  % (index, len(operations), len(chunk), status))
        if status not in (200, 201, 202, 204):
            raise AscError(
                "Upload chunk %d failed with HTTP %s: %s"
                % (index, status, (body or b"")[:400].decode("utf-8", "replace"))
            )


def upload_asset(client, reserve_body, reserve_path, commit_path_template, path, out):
    """Reserve -> upload -> commit one binary asset.

    Apple's three-step asset flow: POST to reserve (returns uploadOperations),
    PUT the bytes, then PATCH with uploaded=true and the md5 sourceFileChecksum.
    """
    data = path.read_bytes()
    checksum = hashlib.md5(data).hexdigest()

    reserved = client.post(reserve_path, reserve_body)
    asset_id = reserved["data"]["id"]
    operations = attributes_of(reserved["data"]).get("uploadOperations") or []
    run_upload_operations(client, operations, data, out)

    commit_body = {
        "data": {
            "type": reserve_body["data"]["type"],
            "id": asset_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
        }
    }
    client.patch(commit_path_template % asset_id, commit_body)
    return asset_id


def ensure_screenshot_set(client, localization_id, plan):
    sets = client.get_all(
        "/v1/appStoreVersionLocalizations/%s/appScreenshotSets" % localization_id
    )
    for screenshot_set in sets:
        if attributes_of(screenshot_set).get("screenshotDisplayType") == SCREENSHOT_DISPLAY_TYPE:
            plan.note("screenshot set %s exists" % SCREENSHOT_DISPLAY_TYPE)
            return screenshot_set["id"]
    body = {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": SCREENSHOT_DISPLAY_TYPE},
            "relationships": {
                "appStoreVersionLocalization": relationship(
                    "appStoreVersionLocalizations", localization_id
                )
            },
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appScreenshotSets
    created = plan.act(
        "create the %s screenshot set" % SCREENSHOT_DISPLAY_TYPE,
        lambda: client.post("/v1/appScreenshotSets", body),
    )
    if is_pending(created):
        return PENDING
    return created["data"]["id"]


def cmd_screenshots(client, args, out):
    plan = Plan(dry_run=args.dry_run, out=out)
    if not SCREENSHOT_DIR.is_dir():
        raise AscError(
            "No screenshot directory at %s\n"
            "  Expected 6.9-inch iPhone PNGs (%d x %d) there."
            % (SCREENSHOT_DIR, SCREENSHOT_EXPECTED_SIZE[0], SCREENSHOT_EXPECTED_SIZE[1])
        )
    files = sorted(SCREENSHOT_DIR.glob("*.png"), key=lambda p: p.name)
    if not files:
        raise AscError("No .png files in %s" % SCREENSHOT_DIR)
    if len(files) > 10:
        raise AscError("App Store Connect accepts at most 10 screenshots per set; found %d." % len(files))

    out.write("Screenshots in %s\n" % SCREENSHOT_DIR)
    local = []
    for path in files:
        dimensions = png_dimensions(path)
        if dimensions is None:
            raise AscError("%s is not a readable PNG." % path)
        if dimensions != SCREENSHOT_EXPECTED_SIZE:
            raise AscError(
                "%s is %dx%d; the 6.9-inch set needs %dx%d portrait."
                % (path.name, dimensions[0], dimensions[1],
                   SCREENSHOT_EXPECTED_SIZE[0], SCREENSHOT_EXPECTED_SIZE[1])
            )
        checksum = md5_of(path)
        local.append({"path": path, "checksum": checksum, "size": path.stat().st_size})
        out.write("  %-28s %5dx%-5d %s\n" % (path.name, dimensions[0], dimensions[1], checksum[:12]))

    app = require_app(client)
    version_id = ensure_app_store_version(client, app["id"], plan)
    if is_pending(version_id):
        plan.defer("upload %d screenshots" % len(local))
        summarise(plan, out, "screenshots")
        return 0
    localization_id = ensure_version_localization(client, version_id, {}, plan, announce=False)
    if is_pending(localization_id):
        plan.defer("upload %d screenshots" % len(local))
        summarise(plan, out, "screenshots")
        return 0

    out.write("\nScreenshot set\n")
    set_id = ensure_screenshot_set(client, localization_id, plan)
    if is_pending(set_id):
        plan.defer("upload %d screenshots" % len(local))
        summarise(plan, out, "screenshots")
        return 0

    existing = client.get_all("/v1/appScreenshotSets/%s/appScreenshots" % set_id)
    have = {}
    for screenshot in existing:
        attrs = attributes_of(screenshot)
        state = (attrs.get("assetDeliveryState") or {}).get("state")
        if attrs.get("sourceFileChecksum") and state != "FAILED":
            have[attrs["sourceFileChecksum"]] = screenshot["id"]

    out.write("\nUpload\n")
    ordered_ids = []
    for item in local:
        if item["checksum"] in have:
            plan.note("%s already uploaded" % item["path"].name)
            ordered_ids.append(have[item["checksum"]])
            continue

        def do_upload(item=item):
            body = {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {
                        "fileName": item["path"].name,
                        "fileSize": item["size"],
                    },
                    "relationships": {
                        "appScreenshotSet": relationship("appScreenshotSets", set_id)
                    },
                }
            }
            # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appScreenshots
            return upload_asset(
                client, body, "/v1/appScreenshots", "/v1/appScreenshots/%s",
                item["path"], out,
            )

        asset_id = plan.act("upload %s (%d bytes)" % (item["path"].name, item["size"]), do_upload)
        if not is_pending(asset_id):
            ordered_ids.append(asset_id)

    if ordered_ids and not args.dry_run:
        # Put the set in filename order.
        # https://developer.apple.com/documentation/AppStoreConnectAPI/PATCH-v1-appScreenshotSets-_id_-relationships-appScreenshots
        current_order = [s["id"] for s in existing]
        if current_order != ordered_ids:
            body = {"data": [{"type": "appScreenshots", "id": i} for i in ordered_ids]}
            plan.act(
                "order the set by filename",
                lambda: client.patch(
                    "/v1/appScreenshotSets/%s/relationships/appScreenshots" % set_id,
                    body,
                    expect=(200, 204),
                ),
            )

    summarise(plan, out, "screenshots")
    return 0


# ---------------------------------------------------------------------------
# Review details + IAP review screenshot
# ---------------------------------------------------------------------------


def ensure_review_detail(client, version_id, contact, notes, plan):
    if is_pending(version_id):
        plan.defer("set App Review contact details")
        return
    current = client.get_optional("/v1/appStoreVersions/%s/appStoreReviewDetail" % version_id)

    wanted = {"demoAccountRequired": False}
    if contact:
        wanted.update(
            {
                "contactFirstName": contact["first_name"],
                "contactLastName": contact["last_name"],
                "contactPhone": contact["phone"],
                "contactEmail": contact["email"],
            }
        )
    if notes:
        wanted["notes"] = notes

    if current and (current.get("data") or {}).get("id"):
        detail_id = current["data"]["id"]
        attrs = attributes_of(current["data"])
        changed = {k: v for k, v in wanted.items() if attrs.get(k) != v}
        if not changed:
            plan.note("App Review details are current")
            return
        body = {
            "data": {"type": "appStoreReviewDetails", "id": detail_id, "attributes": changed}
        }
        plan.act(
            "update App Review details (%s)" % ", ".join(sorted(changed)),
            lambda: client.patch("/v1/appStoreReviewDetails/%s" % detail_id, body),
        )
        return

    body = {
        "data": {
            "type": "appStoreReviewDetails",
            "attributes": wanted,
            "relationships": {"appStoreVersion": relationship("appStoreVersions", version_id)},
        }
    }
    # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-appStoreReviewDetails
    plan.act("create App Review details", lambda: client.post("/v1/appStoreReviewDetails", body))


def ensure_iap_review_screenshot(client, subscription_id, product_id, plan, out):
    """Attach the paywall screenshot App Review needs for each subscription."""
    if is_pending(subscription_id):
        plan.defer("attach the review screenshot to %s" % product_id)
        return
    current = client.get_optional(
        "/v1/subscriptions/%s/appStoreReviewScreenshot" % subscription_id
    )
    checksum = md5_of(IAP_SCREENSHOT)
    if current and (current.get("data") or {}).get("id"):
        attrs = attributes_of(current["data"])
        state = (attrs.get("assetDeliveryState") or {}).get("state")
        if attrs.get("sourceFileChecksum") == checksum and state != "FAILED":
            plan.note("%s already has the current review screenshot" % product_id)
            return
        plan.warn(
            "%s has a different review screenshot (state %s). Delete it in App Store\n"
            "      Connect if you want this one to replace it." % (product_id, state)
        )
        return

    def do_upload():
        body = {
            "data": {
                "type": "subscriptionAppStoreReviewScreenshots",
                "attributes": {
                    "fileName": IAP_SCREENSHOT.name,
                    "fileSize": IAP_SCREENSHOT.stat().st_size,
                },
                "relationships": {"subscription": relationship("subscriptions", subscription_id)},
            }
        }
        # https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionAppStoreReviewScreenshots
        return upload_asset(
            client,
            body,
            "/v1/subscriptionAppStoreReviewScreenshots",
            "/v1/subscriptionAppStoreReviewScreenshots/%s",
            IAP_SCREENSHOT,
            out,
        )

    plan.act("attach the review screenshot to %s" % product_id, do_upload)


def cmd_review(client, args, out):
    if getattr(args, "action", None) == "submit":
        return cmd_review_submit(client, args, out)
    plan = Plan(dry_run=args.dry_run, out=out)
    app = require_app(client)
    out.write("App: %s (id %s)\n" % (attributes_of(app).get("name"), app["id"]))

    contact = load_review_contact(args.key_dir)
    if contact is None:
        out.write(
            "\n  ! No review-contact.json beside the API key, so App Review contact\n"
            "    details are being skipped. Add\n"
            "      ~/Rendprop AI/_bridge/.asc/review-contact.json\n"
            "      {\"first_name\":..,\"last_name\":..,\"phone\":..,\"email\":..}\n"
            "    and re-run, or fill them in App Store Connect -> your app -> the\n"
            "    version -> App Review Information.\n"
        )

    notes = None
    if REVIEW_NOTES_FILE.is_file():
        notes = REVIEW_NOTES_FILE.read_text(encoding="utf-8").strip()
        if len(notes) > 4000:
            raise AscError(
                "%s is %d characters; App Review notes allow 4000."
                % (REVIEW_NOTES_FILE, len(notes))
            )
        out.write("Review notes: %s (%d characters)\n" % (REVIEW_NOTES_FILE.name, len(notes)))
    else:
        out.write("Review notes: %s not present, skipping.\n" % REVIEW_NOTES_FILE)

    out.write("\nApp Review details\n")
    version_id = ensure_app_store_version(client, app["id"], plan)
    ensure_review_detail(client, version_id, contact, notes, plan)

    out.write("\nSubscription review screenshots\n")
    if not IAP_SCREENSHOT.is_file():
        plan.warn(
            "no %s, so no subscription review screenshots were attached.\n"
            "      App Review usually rejects subscriptions without one." % IAP_SCREENSHOT
        )
    else:
        group = find_group(client, app["id"])
        if group is None:
            plan.warn("no %r subscription group yet; run `subscriptions apply` first."
                      % SUBSCRIPTION_GROUP_REFERENCE_NAME)
        else:
            by_product = {
                attributes_of(s).get("productId"): s
                for s in client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group["id"])
            }
            for spec in SUBSCRIPTIONS:
                subscription = by_product.get(spec["productId"])
                if subscription is None:
                    plan.warn("%s does not exist yet" % spec["productId"])
                    continue
                ensure_iap_review_screenshot(
                    client, subscription["id"], spec["productId"], plan, out
                )

    summarise(plan, out, "review")
    return 0


# Subscription states, from filter[state] on the subscriptions endpoint:
# MISSING_METADATA, READY_TO_SUBMIT, WAITING_FOR_REVIEW, IN_REVIEW,
# DEVELOPER_ACTION_NEEDED, PENDING_BINARY_APPROVAL, APPROVED,
# DEVELOPER_REMOVED_FROM_SALE, REMOVED_FROM_SALE, REJECTED.
SUBMITTABLE_STATE = "READY_TO_SUBMIT"
ALREADY_SUBMITTED_STATES = {
    "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_BINARY_APPROVAL", "APPROVED",
}


def cmd_review_submit(client, args, out):
    """Submit each ready subscription for review. Never run by `apply`.

    The resource is `subscriptionSubmissions`; there is no
    `subscriptionAppStoreReviewSubmissions` in Apple's spec. A whole group can
    also be submitted at once via POST /v1/subscriptionGroupSubmissions.
    https://developer.apple.com/documentation/AppStoreConnectAPI/POST-v1-subscriptionSubmissions
    """
    plan = Plan(dry_run=args.dry_run, out=out)
    app = require_app(client)
    group = find_group(client, app["id"])
    if group is None:
        raise AscError(
            "No %r subscription group - run `subscriptions apply` first."
            % SUBSCRIPTION_GROUP_REFERENCE_NAME
        )

    subscriptions = client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group["id"])
    by_product = {attributes_of(s).get("productId"): s for s in subscriptions}

    out.write("Subscriptions in %r\n\n" % SUBSCRIPTION_GROUP_REFERENCE_NAME)
    blocked = []
    for spec in SUBSCRIPTIONS:
        subscription = by_product.get(spec["productId"])
        if subscription is None:
            plan.warn("%s does not exist" % spec["productId"])
            blocked.append(spec["productId"])
            continue
        state = attributes_of(subscription).get("state")

        if state in ALREADY_SUBMITTED_STATES:
            plan.note("%s is already %s" % (spec["productId"], state))
            continue
        if state != SUBMITTABLE_STATE:
            plan.warn(
                "%s is %s, not %s - it cannot be submitted yet.%s"
                % (spec["productId"], state, SUBMITTABLE_STATE,
                   "\n      MISSING_METADATA usually means no localization, no price, no\n"
                   "      availability, or no App Review screenshot. Run\n"
                   "      `asc.py subscriptions apply` then `asc.py review apply`."
                   if state == "MISSING_METADATA" else "")
            )
            blocked.append(spec["productId"])
            continue

        body = {
            "data": {
                "type": "subscriptionSubmissions",
                "relationships": {
                    "subscription": relationship("subscriptions", subscription["id"])
                },
            }
        }

        def submit(body=body, spec=spec):
            try:
                return client.post("/v1/subscriptionSubmissions", body)
            except ApiError as exc:
                plan.warn("could not submit %s (%s)"
                          % (spec["productId"], ", ".join(exc.codes) or exc.status))
                blocked.append(spec["productId"])
                return None

        plan.act("submit %s for review" % spec["productId"], submit)

    out.write("\n")
    if blocked:
        out.write("Not submitted: %s\n" % ", ".join(sorted(set(blocked))))
        out.write("Run `python3 tools/asc/asc.py status` to see what each one is missing.\n")
        return 1
    summarise(plan, out, "submission")
    return 0


def find_group(client, app_id):
    for group in client.get_all("/v1/apps/%s/subscriptionGroups" % app_id):
        if attributes_of(group).get("referenceName") == SUBSCRIPTION_GROUP_REFERENCE_NAME:
            return group
    return None


# ---------------------------------------------------------------------------
# app + status
# ---------------------------------------------------------------------------


def cmd_app(client, args, out):
    app = find_app(client)
    if app is None:
        out.write("No app record found for bundle id %s.\n" % BUNDLE_ID)
        print_new_app_form(out)
        return 1
    attrs = attributes_of(app)
    out.write("Found the app record.\n\n")
    out.write("  Name ............. %s\n" % attrs.get("name"))
    out.write("  Bundle ID ........ %s\n" % attrs.get("bundleId"))
    out.write("  SKU .............. %s\n" % attrs.get("sku"))
    out.write("  Apple ID ......... %s\n" % app["id"])
    out.write("  Primary locale ... %s\n" % attrs.get("primaryLocale"))
    out.write("  Content rights ... %s\n" % attrs.get("contentRightsDeclaration"))
    out.write("\n  App Store Server Notifications\n")
    out.write("    production ..... %s (%s)\n"
              % (attrs.get("subscriptionStatusUrl") or "not set",
                 attrs.get("subscriptionStatusUrlVersion") or "-"))
    out.write("    sandbox ........ %s (%s)\n"
              % (attrs.get("subscriptionStatusUrlForSandbox") or "not set",
                 attrs.get("subscriptionStatusUrlVersionForSandbox") or "-"))
    if attrs.get("primaryLocale") != PRIMARY_LOCALE:
        out.write("\n  ! Primary locale is %s, expected %s.\n"
                  % (attrs.get("primaryLocale"), PRIMARY_LOCALE))
    return 0


def cmd_status(client, args, out):
    missing = []
    report = {}

    app = find_app(client)
    if app is None:
        out.write("APP\n  not created - run `asc.py app` for the New App form values\n")
        if args.json:
            json.dump({"app": None, "missing": ["app record"]}, out, indent=2)
            out.write("\n")
        return 1
    attrs = attributes_of(app)
    report["app"] = {"id": app["id"], "name": attrs.get("name"), "bundleId": attrs.get("bundleId")}

    out.write("APP\n")
    out.write("  %s  (Apple ID %s, %s)\n" % (attrs.get("name"), app["id"], attrs.get("bundleId")))
    production = attrs.get("subscriptionStatusUrl")
    sandbox = attrs.get("subscriptionStatusUrlForSandbox")
    out.write("  server notifications: production %s / sandbox %s\n"
              % ("set" if production else "NOT SET", "set" if sandbox else "NOT SET"))
    if production != NOTIFICATION_URL or sandbox != NOTIFICATION_URL:
        missing.append("App Store Server Notification V2 URLs")

    app_availability = client.get_optional("/v1/apps/%s/appAvailabilityV2" % app["id"])
    app_territories = []
    if app_availability and (app_availability.get("data") or {}).get("id"):
        rows = client.get_all(
            "/v2/appAvailabilities/%s/territoryAvailabilities" % app_availability["data"]["id"],
            params={"include": "territory", "limit": 200},
        )
        app_territories = sorted(
            t for t in (
                (((r.get("relationships") or {}).get("territory") or {}).get("data") or {}).get("id")
                for r in rows if attributes_of(r).get("available")
            ) if t
        )
    out.write("  app availability: %s\n"
              % (",".join(app_territories) if 0 < len(app_territories) <= 3
                 else ("%d territories" % len(app_territories) if app_territories else "NOT SET")))
    if app_territories and app_territories != sorted(LAUNCH_TERRITORIES):
        missing.append("app availability is %d territories, launch is %s only"
                       % (len(app_territories), ",".join(LAUNCH_TERRITORIES)))
    report["appTerritories"] = app_territories

    # --- version -----------------------------------------------------------
    out.write("\nVERSION\n")
    versions = client.get_all(
        "/v1/apps/%s/appStoreVersions" % app["id"], params={"filter[platform]": PLATFORM}
    )
    version = find_editable_version(client, app["id"])
    if not versions:
        out.write("  none\n")
        missing.append("App Store version %s" % VERSION_STRING)
    for item in versions[:5]:
        item_attrs = attributes_of(item)
        marker = "*" if version and item["id"] == version["id"] else " "
        out.write("  %s %-6s %-28s %s\n"
                  % (marker, item_attrs.get("versionString"),
                     item_attrs.get("appVersionState") or item_attrs.get("appStoreState"),
                     item_attrs.get("copyright") or "no copyright"))
    report["versions"] = [attributes_of(v).get("versionString") for v in versions]

    localization = None
    if version:
        localizations = client.get_all(
            "/v1/appStoreVersions/%s/appStoreVersionLocalizations" % version["id"]
        )
        for candidate in localizations:
            if attributes_of(candidate).get("locale") == PRIMARY_LOCALE:
                localization = candidate
        out.write("\nLISTING (%s)\n" % PRIMARY_LOCALE)
        if localization is None:
            out.write("  no %s localization\n" % PRIMARY_LOCALE)
            missing.append("%s listing copy" % PRIMARY_LOCALE)
        else:
            loc_attrs = attributes_of(localization)
            for field in ("description", "keywords", "promotionalText", "whatsNew",
                          "supportUrl", "marketingUrl"):
                value = loc_attrs.get(field)
                out.write("  %-16s %s\n"
                          % (field, ("%d chars" % len(value)) if value else "MISSING"))
                if not value and field in ("description", "keywords", "supportUrl"):
                    missing.append("listing %s" % field)

    # --- app info ----------------------------------------------------------
    out.write("\nAPP INFORMATION\n")
    app_info = editable_app_info(client, app["id"])
    info_rel = app_info.get("relationships") or {}
    primary = ((info_rel.get("primaryCategory") or {}).get("data") or {}).get("id")
    secondary = ((info_rel.get("secondaryCategory") or {}).get("data") or {}).get("id")
    out.write("  categories ....... %s / %s\n" % (primary or "NOT SET", secondary or "NOT SET"))
    if primary != PRIMARY_CATEGORY or secondary != SECONDARY_CATEGORY:
        missing.append("categories (%s / %s)" % (PRIMARY_CATEGORY, SECONDARY_CATEGORY))
    out.write("  age rating ....... %s\n" % (attributes_of(app_info).get("appStoreAgeRating") or "not set"))
    info_locs = client.get_all("/v1/appInfos/%s/appInfoLocalizations" % app_info["id"])
    for candidate in info_locs:
        candidate_attrs = attributes_of(candidate)
        if candidate_attrs.get("locale") == PRIMARY_LOCALE:
            out.write("  name ............. %s\n" % (candidate_attrs.get("name") or "NOT SET"))
            out.write("  subtitle ......... %s\n" % (candidate_attrs.get("subtitle") or "NOT SET"))
            out.write("  privacy policy ... %s\n" % (candidate_attrs.get("privacyPolicyUrl") or "NOT SET"))
            if not candidate_attrs.get("privacyPolicyUrl"):
                missing.append("privacy policy URL")

    # --- screenshots -------------------------------------------------------
    out.write("\nSCREENSHOTS\n")
    screenshot_count = 0
    if localization:
        sets = client.get_all(
            "/v1/appStoreVersionLocalizations/%s/appScreenshotSets" % localization["id"]
        )
        if not sets:
            out.write("  none\n")
        for screenshot_set in sets:
            shots = client.get_all("/v1/appScreenshotSets/%s/appScreenshots" % screenshot_set["id"])
            display_type = attributes_of(screenshot_set).get("screenshotDisplayType")
            if display_type == SCREENSHOT_DISPLAY_TYPE:
                screenshot_count = len(shots)
            out.write("  %-22s %d image(s)\n" % (display_type, len(shots)))
    if screenshot_count < 3:
        missing.append("6.9-inch screenshots (%s, have %d, need 3-10)"
                       % (SCREENSHOT_DISPLAY_TYPE, screenshot_count))
    report["screenshots"] = screenshot_count

    # --- subscriptions -----------------------------------------------------
    out.write("\nSUBSCRIPTIONS\n")
    group = find_group(client, app["id"])
    products = []
    if group is None:
        out.write("  group %r does not exist\n" % SUBSCRIPTION_GROUP_REFERENCE_NAME)
        missing.append("subscription group %r" % SUBSCRIPTION_GROUP_REFERENCE_NAME)
    else:
        group_locs = client.get_all(
            "/v1/subscriptionGroups/%s/subscriptionGroupLocalizations" % group["id"]
        )
        names = [attributes_of(g).get("name") for g in group_locs
                 if attributes_of(g).get("locale") == PRIMARY_LOCALE]
        out.write("  group %s  display name %r\n"
                  % (SUBSCRIPTION_GROUP_REFERENCE_NAME, names[0] if names else "NOT SET"))
        by_product = {
            attributes_of(s).get("productId"): s
            for s in client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group["id"])
        }
        out.write("  %-34s %-17s %-8s %-18s %-6s %-5s %s\n"
                  % ("product", "state", "avail", "prices", "trial", "loc", "shot"))
        for spec in SUBSCRIPTIONS:
            subscription = by_product.get(spec["productId"])
            if subscription is None:
                out.write("  %-34s %s\n" % (spec["productId"], "MISSING"))
                missing.append(spec["productId"])
                continue
            sub_id = subscription["id"]
            state = attributes_of(subscription).get("state")
            prices = client.get_all(
                "/v1/subscriptions/%s/prices" % sub_id,
                params={"include": "territory", "limit": 200},
            )
            offers = client.get_all("/v1/subscriptions/%s/introductoryOffers" % sub_id)
            locs = client.get_all("/v1/subscriptions/%s/subscriptionLocalizations" % sub_id)
            shot = client.get_optional("/v1/subscriptions/%s/appStoreReviewScreenshot" % sub_id)

            # Availability returns 404 until it has been set.
            availability = client.get_optional(
                "/v1/subscriptions/%s/subscriptionAvailability" % sub_id)
            territories_listed = []
            if availability and (availability.get("data") or {}).get("id"):
                territories_listed = [t["id"] for t in client.get_all(
                    "/v1/subscriptionAvailabilities/%s/availableTerritories"
                    % availability["data"]["id"])]

            price_territories = sorted(priced_territories(prices))
            if territories_listed:
                avail_text = (",".join(sorted(territories_listed))
                              if len(territories_listed) <= 2
                              else "%d terr" % len(territories_listed))
            else:
                avail_text = "NONE"
            if price_territories:
                price_text = ("%d (%s)" % (len(prices), ",".join(price_territories))
                              if len(price_territories) <= 2
                              else "%d prices" % len(prices))
            else:
                price_text = "%d (?)" % len(prices) if prices else "NONE"

            out.write("  %-34s %-17s %-8s %-18s %-6s %-5s %s\n"
                      % (spec["productId"], state or "?", avail_text, price_text,
                         "yes" if offers else "NO", len(locs), "yes" if shot else "NO"))

            for label, ok in (("price", prices), ("free trial", offers),
                              ("availability", territories_listed), ("localization", locs),
                              ("review screenshot", shot)):
                if not ok:
                    missing.append("%s %s" % (spec["productId"], label))
            if territories_listed and sorted(territories_listed) != sorted(LAUNCH_TERRITORIES):
                missing.append(
                    "%s availability is %d territories, launch is %s only"
                    % (spec["productId"], len(territories_listed), ",".join(LAUNCH_TERRITORIES)))
            unpriced = [t for t in territories_listed if t not in price_territories]
            if unpriced:
                missing.append("%s has no price in %d territor%s it sells in"
                               % (spec["productId"], len(unpriced),
                                  "y" if len(unpriced) == 1 else "ies"))
            if state == "MISSING_METADATA":
                missing.append("%s is MISSING_METADATA (not yet submittable)" % spec["productId"])
            products.append({
                "productId": spec["productId"], "state": state,
                "territories": sorted(territories_listed),
                "pricedTerritories": price_territories,
                "introductoryOffers": len(offers),
                "localizations": len(locs),
                "reviewScreenshot": bool(shot),
            })
    report["subscriptions"] = products

    # --- review details ----------------------------------------------------
    out.write("\nAPP REVIEW\n")
    if version:
        detail = client.get_optional("/v1/appStoreVersions/%s/appStoreReviewDetail" % version["id"])
        if detail and (detail.get("data") or {}).get("id"):
            detail_attrs = attributes_of(detail["data"])
            has_contact = all(detail_attrs.get(k) for k in
                              ("contactFirstName", "contactLastName", "contactPhone", "contactEmail"))
            out.write("  contact .......... %s\n" % ("set" if has_contact else "INCOMPLETE"))
            out.write("  notes ............ %s\n"
                      % ("%d chars" % len(detail_attrs["notes"]) if detail_attrs.get("notes") else "none"))
            if not has_contact:
                missing.append("App Review contact details")
        else:
            out.write("  not set\n")
            missing.append("App Review details")

    # --- builds ------------------------------------------------------------
    out.write("\nBUILDS\n")
    builds = client.get_all(
        "/v1/builds",
        params={"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 10},
    )
    if not builds:
        out.write("  none uploaded - run tools/asc/bridge-600-archive-upload.sh\n")
        missing.append("a TestFlight build")
    for build in builds[:10]:
        build_attrs = attributes_of(build)
        out.write("  %-10s %-12s uploaded %s\n"
                  % (build_attrs.get("version"), build_attrs.get("processingState"),
                     build_attrs.get("uploadedDate")))
    report["builds"] = len(builds)

    if version:
        attached = client.get_optional("/v1/appStoreVersions/%s/build" % version["id"])
        out.write("  attached to %s: %s\n"
                  % (VERSION_STRING, "yes" if attached else "NO - pick a build in App Store Connect"))
        if not attached:
            missing.append("a build attached to version %s" % VERSION_STRING)

    # --- summary -----------------------------------------------------------
    out.write("\nWHAT IS MISSING\n")
    if not missing:
        out.write("  nothing this tool can see. Remaining manual steps are in\n")
        out.write("  docs/appstore/ASC-API-PLAN.md (privacy labels, agreements, submission).\n")
    for item in missing:
        out.write("  - %s\n" % item)

    out.write("\nAlways manual (not in the API): privacy nutrition labels, the Paid\n")
    out.write("Applications agreement and banking/tax, and sandbox tester creation.\n")
    out.write("See docs/appstore/ASC-API-PLAN.md.\n")

    if client.rate_limit:
        out.write("\nX-Rate-Limit: %s\n" % client.rate_limit)

    if args.json:
        report["missing"] = missing
        out.write("\n")
        json.dump(report, out, indent=2)
        out.write("\n")
    return 1 if missing else 0


def summarise(plan, out, label):
    out.write("\n")
    if plan.dry_run:
        out.write("Plan for %s: %d change(s) would be made" % (label, plan.changes))
        if plan.skipped:
            out.write(", %d more step(s) become plannable once those exist" % plan.skipped)
        out.write(".\nRe-run without --dry-run to apply.\n")
    elif plan.changes:
        out.write("%s: %d change(s) applied.\n" % (label.capitalize(), plan.changes))
    else:
        out.write("%s: already correct, nothing to do.\n" % label.capitalize())


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog="asc.py",
        description="Create Rendprop's subscriptions and fill its App Store listing.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Every command reads the current state first and only creates what is\n"
            "missing, so running any of them twice is safe.\n\n"
            "The API key is read from ~/Rendprop AI/_bridge/.asc/ and never printed.\n"
        ),
    )
    parser.add_argument("--key-dir", default=None,
                        help="override the directory holding AuthKey_*.p8 and config")
    parser.add_argument("--json", action="store_true", help="also print machine-readable JSON")
    parser.add_argument("--quiet", action="store_true", help="do not log HTTP requests")
    parser.add_argument("--debug", action="store_true",
                        help="on a failed request, print the exact JSON body that was "
                             "sent (never the credentials)")

    sub = parser.add_subparsers(dest="command")

    sub.add_parser("app", help="find the app record, or print the New App form values")

    for name, help_text in (
        ("subscriptions", "create the subscription group, products, prices, trials"),
        ("metadata", "fill the App Store listing from docs/appstore/metadata/en-US"),
        ("screenshots", "upload docs/appstore/screenshots/6.9/*.png"),
        ("review", "set App Review details and the subscription review screenshot"),
    ):
        # `review` also takes `submit`, which sends the subscriptions to App
        # Review. It is never part of `apply` - submitting is the owner's call.
        actions = ["plan", "apply"] + (["submit"] if name == "review" else [])
        command = sub.add_parser(name, help=help_text)
        command.add_argument(
            "action", choices=actions,
            help="plan = show what would change; apply = do it"
                 + ("; submit = send the subscriptions to App Review" if name == "review" else ""),
        )
        command.add_argument("--dry-run", action="store_true",
                             help="same as the plan action")

    sub.add_parser("status", help="one-page summary of everything and what is missing")
    return parser


COMMANDS = {
    "app": cmd_app,
    "subscriptions": cmd_subscriptions,
    "metadata": cmd_metadata,
    "screenshots": cmd_screenshots,
    "review": cmd_review,
    "status": cmd_status,
}


def main(argv=None, out=None, client=None):
    out = out or sys.stdout
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help(out)
        return 2

    # `plan` is the same thing as `apply --dry-run`.
    args.dry_run = bool(getattr(args, "dry_run", False)) or getattr(args, "action", None) == "plan"

    try:
        if client is None:
            credentials = load_credentials(args.key_dir)
            client = Client(credentials, verbose=not args.quiet, out=out,
                            debug=getattr(args, "debug", False))
        return COMMANDS[args.command](client, args, out)
    except AscError as exc:
        out.write("\nFAILED\n")
        sys.stderr.write("%s\n" % exc)
        return 1
    except KeyboardInterrupt:
        sys.stderr.write("\nInterrupted.\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
