#!/usr/bin/env python3
"""
Cloudflare R2 helpers over the S3 API (boto3).

R2 is S3-compatible: point boto3 at the account endpoint
`https://<account>.r2.cloudflarestorage.com`, region "auto", SigV4. Zero egress,
so we move bytes freely (AI-COST-MODEL.md §3).

The worker uses three operations:
  • download_file  — pull the raw capture (.mov) from `rendprop-uploads`.
  • upload_file    — push the encoded mp4 + poster (+ enhanced stills) to
                     `rendprop-renders`.
  • presigned_get_url — a time-limited GET on the uploaded mp4 that we hand to
                     Cloudflare Stream's copy-from-URL (so the bucket needn't be
                     public and no bytes route through us).

boto3 is created lazily and cached; a clean error is raised if R2 creds are
missing so the worker can fail the job with a useful message instead of a stack
trace deep inside botocore.
"""

from __future__ import annotations

import mimetypes
import os
from functools import lru_cache

import boto3
from botocore.client import Config
from botocore.exceptions import BotoCoreError, ClientError

from settings import SETTINGS


class R2Error(RuntimeError):
    """Any R2/S3-side failure, normalized for the worker."""


@lru_cache(maxsize=1)
def _client():
    if not SETTINGS.has_r2:
        raise R2Error(
            "R2 not configured — set CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, "
            "R2_SECRET_ACCESS_KEY (see .env.example)."
        )
    return boto3.client(
        "s3",
        endpoint_url=SETTINGS.r2_endpoint,
        aws_access_key_id=SETTINGS.r2_access_key_id,
        aws_secret_access_key=SETTINGS.r2_secret_access_key,
        region_name="auto",
        config=Config(signature_version="s3v4", retries={"max_attempts": 3, "mode": "standard"}),
    )


def download_file(bucket: str, key: str, dest_path: str) -> str:
    """Download `key` from `bucket` to a local path. Returns the local path."""
    os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)
    try:
        _client().download_file(bucket, key, dest_path)
    except (BotoCoreError, ClientError) as e:
        raise R2Error(f"R2 download failed for s3://{bucket}/{key}: {e}") from e
    return dest_path


def upload_file(local_path: str, bucket: str, key: str, content_type: str | None = None) -> str:
    """Upload a local file to `bucket/key`. Returns the object key."""
    if content_type is None:
        content_type = mimetypes.guess_type(local_path)[0] or "application/octet-stream"
    try:
        _client().upload_file(
            local_path, bucket, key, ExtraArgs={"ContentType": content_type}
        )
    except (BotoCoreError, ClientError) as e:
        raise R2Error(f"R2 upload failed for s3://{bucket}/{key}: {e}") from e
    return key


def presigned_get_url(bucket: str, key: str, expires_s: int | None = None) -> str:
    """Time-limited GET url — used as Cloudflare Stream's copy-from-URL source."""
    expires_s = expires_s or SETTINGS.r2_presign_expiry_s
    try:
        return _client().generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=int(expires_s),
        )
    except (BotoCoreError, ClientError) as e:
        raise R2Error(f"R2 presign failed for s3://{bucket}/{key}: {e}") from e
