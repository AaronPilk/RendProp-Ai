"""Lease-scoped transport only. The controlling Worker intercepts all egress.

No redirects, environment proxies, supplied headers, credentials or non-HTTPS
addresses. A task has only the exact signed GET/PUT capabilities issued by Edge.
The container does not receive provider, R2 or Supabase administrator keys.
"""
import hashlib
import http.client
import ipaddress
import os
import ssl
import time
from pathlib import Path
from urllib.parse import urlsplit

MAX_MEDIA_BYTES = 128 * 1024 * 1024
MAX_MASTER_BYTES = 1536 * 1024 * 1024


def checked_url(raw, allowed_hosts):
    if not isinstance(raw, str) or len(raw) > 8192:
        raise ValueError("invalid_media_capability")
    url = urlsplit(raw)
    if (url.scheme != "https" or url.username or url.password or url.fragment
            or url.port not in {None, 443} or not url.hostname
            or url.hostname not in allowed_hosts or not url.path.startswith("/")):
        raise ValueError("invalid_media_capability")
    try:
        ipaddress.ip_address(url.hostname)
    except ValueError:
        pass
    else:
        raise ValueError("IP_media_capability_refused")
    return url


def context():
    ctx = ssl.create_default_context()
    ca = Path("/etc/cloudflare/certs/cloudflare-containers-ca.crt")
    if ca.is_file():
        ctx.load_verify_locations(cafile=str(ca))
    return ctx


def connect(raw, allowed_hosts):
    url = checked_url(raw, allowed_hosts)
    return http.client.HTTPSConnection(url.hostname, timeout=60, context=context()), url.path + ("?" + url.query if url.query else "")


def digest(path):
    sha = hashlib.sha256()
    with Path(path).open("rb") as source:
        while chunk := source.read(1024 * 1024):
            sha.update(chunk)
    return sha.hexdigest()


def download(item, target, allowed_hosts, *, max_bytes=MAX_MEDIA_BYTES, hash_optional=False):
    expected = item.get("bytes")
    expected_sha = item.get("sha256") or item.get("asset_sha256")
    if (not isinstance(expected, int) or isinstance(expected, bool) or not 1 <= expected <= max_bytes
            or (not hash_optional and (not isinstance(expected_sha, str) or len(expected_sha) != 64))):
        raise ValueError("invalid_media_receipt")
    connection, path = connect(item["url"], allowed_hosts)
    try:
        connection.request("GET", path, headers={"Accept-Encoding": "identity"})
        response = connection.getresponse()
        if response.status != 200 or response.getheader("Content-Encoding", "identity") != "identity":
            raise ValueError("media_capability_refused")
        length = response.getheader("Content-Length")
        if length and int(length) != expected:
            raise ValueError("media_size_conflict")
        sha, total = hashlib.sha256(), 0
        with Path(target).open("wb") as output:
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > expected:
                    raise ValueError("media_size_conflict")
                sha.update(chunk)
                output.write(chunk)
        measured = sha.hexdigest()
        if total != expected or (expected_sha is not None and measured != expected_sha):
            raise ValueError("media_hash_conflict")
        return measured
    finally:
        connection.close()


def upload(raw, source, content_type, allowed_hosts, capability_headers, *, allow_existing=False):
    source = Path(source)
    size = source.stat().st_size
    if not 1 <= size <= MAX_MASTER_BYTES:
        raise ValueError("bounded_output_required")
    expected = {"content-length":str(size), "content-type":content_type,
                "x-amz-meta-sha256":digest(source), "if-none-match":"*"}
    if capability_headers != expected:
        raise ValueError("output_header_identity_conflict")
    connection, path = connect(raw, allowed_hosts)
    try:
        connection.putrequest("PUT", path)
        for key,value in expected.items():
            connection.putheader(key,value)
        connection.endheaders()
        with source.open("rb") as content:
            while chunk := content.read(1024 * 1024):
                connection.send(chunk)
        response = connection.getresponse()
        response.read(8192)
        if response.status not in ({200, 201, 204, 412} if allow_existing else {200, 201, 204}):
            raise ValueError("output_capability_refused")
        # Video callers ignore the return; photo comparison binds each immutable
        # upload receipt to the storage ETag for the separate check authority.
        return response.getheader("ETag") if response.status != 412 else None
    finally:
        connection.close()
