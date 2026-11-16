"""Fail-closed funding at the legacy pipeline's paid HTTP boundary.

Only a current worker claim may install a session. Standalone keyed CLI calls
must not evade workspace money authority. Unknown tariffs are allowed solely
for the existing explicitly unlimited private testing sponsorship.
"""
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
import hashlib
import json
import math
import uuid
from urllib.parse import urlsplit

_CURRENT = ContextVar("rendprop_provider_funding", default=None)
_CAPTURE = ContextVar("rendprop_provider_cost_capture", default=None)
VERSION = "published-standard-20261006"
IMAGE_MAX_OUTPUT_TOKENS = 4096


class FundingUnavailable(RuntimeError):
    pass


def paid_identity(url, method, payload):
    if method.upper() != "POST":
        return None
    u = urlsplit(url)
    if u.hostname == "queue.fal.run":
        return "fal", u.path.lstrip("/")
    if u.hostname == "generativelanguage.googleapis.com" and u.path.endswith(":generateContent"):
        return "gemini", u.path.split("/models/", 1)[-1].split(":", 1)[0]
    if u.hostname == "api.anthropic.com" and u.path == "/v1/messages":
        return "anthropic", (payload or {}).get("model", "unknown")
    return None


def quote(provider, model, payload):
    # GenerateContent's maxOutputTokens is an infrastructure-enforced combined
    # thought/output cutoff. Keep the whole published input window and use the
    # highest output tariff, rather than a typical per-image average.
    if provider == "gemini" and model == "gemini-3.1-flash-image":
        if not isinstance(payload, dict) or set(payload) - {"contents", "generationConfig"}:
            return None
        config = payload.get("generationConfig")
        if not isinstance(config, dict):
            return None
        output = config.get("maxOutputTokens")
        if (type(config.get("candidateCount")) is not int or config["candidateCount"] != 1
                or type(output) is not int or not 0 < output <= 32768
                or config.get("responseModalities") != ["IMAGE"]
                or config.get("imageConfig") != {"imageSize": "1K"}
                or set(config) - {"candidateCount", "maxOutputTokens", "responseModalities", "imageConfig"}):
            return None
        return (131072 * .5 + output * 60) / 10000
    if provider == "fal" and model == "fal-ai/flux-pro/kontext" and not (payload or {}).get("mask_url"):
        return 4.0
    # Legacy Fill/Seedance/Topaz and token-based QC need their own verified
    # payload upper bound. Flat historical costs are not authority to spend.
    return None



@dataclass(frozen=True)
class ProviderFundingAttempt:
    reservation_id: str
    actor_id: str
    org_id: str
    request_key: str
    stage: str
    provider: str
    model: str
    input_sha256: str

    def metadata(self):
        return dict(self.__dict__)


@contextmanager
def capture_provider_attempts():
    """Collect only this adapter call's immutable admissions, never raw inputs."""
    attempts = []
    token = _CAPTURE.set(attempts)
    try:
        yield attempts
    finally:
        _CAPTURE.reset(token)


def result_funding(attempts, provider, model):
    # An aggregate/ambiguous result never guesses which supplier attempt it bills.
    if len(attempts) != 1:
        return None
    attempt = attempts[0]
    return attempt if (attempt.provider, attempt.model) == (provider, model) else None


@dataclass
class ServingSession:
    actor_id: str
    org_id: str
    job_id: str
    rpc: object
    authorize: object

    def reserve(self, provider, model, payload, url):
        self.authorize()  # Fresh lease/listing scope before every paid dispatch.
        body = json.dumps({"url": url, "payload": payload}, sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode()
        digest = hashlib.sha256(body).hexdigest()
        cents = quote(provider, model, payload)
        version = VERSION
        if cents is None:
            sponsored = False
            for name in ("org_has_internal_testing_grant", "org_has_private_internal_testing"):
                if self.rpc(name, {"p_org": self.org_id}) is True:
                    sponsored = True
            if not sponsored:
                raise FundingUnavailable("Legacy enhancement tariff is unverified; no generation submitted")
            cents, version = 1.0, "unpriced-private-sponsorship"
        if not math.isfinite(cents) or cents <= 0:
            raise FundingUnavailable("Invalid provider liability")
        stage = "worker:" + digest[:48]
        result = self.rpc("serving_cost_reserve", {
            "p_actor": self.actor_id, "p_org": self.org_id, "p_key": self.job_id,
            "p_stage": stage, "p_provider": provider, "p_model": model,
            "p_input_sha256": digest, "p_hold_cents": math.ceil(cents * 10000) / 10000,
            "p_tariff_version": version,
        })
        if not isinstance(result, dict) or result.get("reserved") is not True:
            raise FundingUnavailable("Provider funding was not confirmed; no generation submitted")
        capture = _CAPTURE.get()
        if capture is not None:
            reservation = result.get("id")
            try:
                valid = isinstance(reservation, str) and str(uuid.UUID(reservation)) == reservation
            except (ValueError, TypeError, AttributeError):
                valid = False
            if not valid:
                raise FundingUnavailable("Immutable provider funding receipt unavailable; no generation submitted")
            capture.append(ProviderFundingAttempt(reservation, self.actor_id, self.org_id,
                self.job_id, stage, provider, model, digest))
        return stage

    def finish(self, stage, state, rejection=None):
        try:
            result = self.rpc("serving_cost_finish", {
                "p_actor": self.actor_id, "p_org": self.org_id, "p_key": self.job_id,
                "p_stage": stage, "p_state": state, "p_rejection_status": rejection,
            })
            if not isinstance(result, dict) or result.get("finished") is not True:
                raise FundingUnavailable("Settlement unconfirmed")
        except Exception:
            # A lost settlement must never release the pre-dispatch liability.
            print("Provider settlement unavailable; reserved liability retained")


@contextmanager
def serving_session(session):
    token = _CURRENT.set(session)
    try:
        yield
    finally:
        _CURRENT.reset(token)


def reserve_paid(url, method, payload):
    identity = paid_identity(url, method, payload)
    if identity is None:
        return None
    session = _CURRENT.get()
    if session is None:
        raise FundingUnavailable("A current funded workspace request is required; no generation submitted")
    return session, session.reserve(*identity, payload, url)
