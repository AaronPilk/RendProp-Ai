# Rendprop render worker — python + ffmpeg, runs worker.py.
#
# BUILD CONTEXT = services/  (the worker imports its sibling services/pipeline).
# From the repo root:
#     docker build -f services/worker/Dockerfile -t rendprop-worker services/
#     docker run --rm --env-file services/worker/.env rendprop-worker
#
# ffmpeg here is a modern build (Debian bookworm) so scale's force_divisible_by
# and, if you enable TONEMAP_HDR, zscale/tonemap are available.

# Digest-pinned (audit supply-chain finding — a bare tag is mutable and can be
# repointed). Resolved 2026-09-07 from the live registry; it's the multi-arch
# index (covers linux/amd64):
#   TOKEN=$(curl -sS 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/python:pull' | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
#   curl -sS -D - -o /dev/null -H "Authorization: Bearer $TOKEN" \
#     -H 'Accept: application/vnd.oci.image.index.v1+json' \
#     https://registry-1.docker.io/v2/library/python/manifests/3.11-slim-bookworm
# Re-resolve (and rebuild + re-test) whenever you deliberately bump the tag.
FROM python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84

# Exact versions resolved 2026-09-07 from the live archive this image's own
# sources.list points at — bookworm main + bookworm-security (the official
# Debian image enables both by default; security carried the newer
# ca-certificates build):
#   curl -s https://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz | xz -dc | awk '/^Package: ffmpeg$/{p=1} p&&/^Version:/{print;p=0}'
#   curl -s https://security.debian.org/debian-security/dists/bookworm-security/main/binary-amd64/Packages.xz | xz -dc | awk '/^Package: ca-certificates$/{p=1} p&&/^Version:/{print;p=0}'
# CAVEAT (unlike the pip pins below): Debian's live archive keeps only the
# newest build per suite, not old ones — once a deb12u2 security update
# ships, deb12u1 disappears and this line starts failing closed rather than
# silently drifting. That is deliberate, matching requirements.txt's own
# philosophy ("bump these deliberately, then rebuild and re-test"): re-run the
# two commands above to find the replacement version, don't just delete the
# pin. Byte-for-byte reproducibility across security updates too would mean
# pinning the apt SOURCE to a snapshot.debian.org date instead of a version
# string — a bigger change than this fix; not done here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ffmpeg=7:5.1.9-0+deb12u1 \
         ca-certificates=20250419~deb12u1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps first for layer caching. The pipeline is stdlib-only; the worker
# needs boto3 + requests.
COPY worker/requirements.txt /app/worker/requirements.txt

# requirements.txt pins every package to an exact `==` (audit round 4) but
# carries NO --hash lines, so --require-hashes is NOT added here: tested
# 2026-09-07, `pip install --require-hashes -r requirements.txt` against this
# exact file fails immediately (exit 1) —
#   ERROR: Hashes are required in --require-hashes mode, but they are missing
#   from some requirements. ... boto3==1.35.99 --hash=sha256:83e560fa...
# Generating real hashes needs a --hash line for all 11 packages in the
# resolved closure, not just the 4 pinned here directly (boto3, botocore,
# requests, urllib3 + their transitive jmespath, s3transfer, python-dateutil,
# charset-normalizer, idna, certifi, six) — normally via
# `pip-compile --generate-hashes` (pip-tools, against a requirements.in) or
# `pip download` + `pip hash` per package — and then re-generating on every
# version bump. That's a real workflow change, flagged here rather than done
# blind; see docs/handoff/audit-fixes.md.
RUN pip install --no-cache-dir -r /app/worker/requirements.txt

# App code: both halves.
COPY pipeline /app/pipeline
COPY worker   /app/worker

# Run as a non-root user — the pipeline processes untrusted, user-uploaded video
# with ffmpeg. A non-root runtime contains the blast radius of any ffmpeg CVE or
# path-handling bug. The workdir must be owned by that user.
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /tmp/rendprop-worker \
    && chown -R appuser:appuser /app /tmp/rendprop-worker

ENV PIPELINE_DIR=/app/pipeline \
    WORKER_WORKDIR=/tmp/rendprop-worker \
    PYTHONUNBUFFERED=1

USER appuser
WORKDIR /app/worker

# Long-running poller by default. For a triggered/serverless run, override with:
#   docker run ... rendprop-worker python worker.py --once
#   docker run ... rendprop-worker python worker.py --job-id <uuid>
CMD ["python", "worker.py"]
