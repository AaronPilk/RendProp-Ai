# Rendprop render worker — python + ffmpeg, runs worker.py.
#
# BUILD CONTEXT = services/  (the worker imports its sibling services/pipeline).
# From the repo root:
#     docker build -f services/worker/Dockerfile -t rendprop-worker services/
#     docker run --rm --env-file services/worker/.env rendprop-worker
#
# ffmpeg here is a modern build (Debian bookworm) so scale's force_divisible_by
# and, if you enable TONEMAP_HDR, zscale/tonemap are available.

FROM python:3.11-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps first for layer caching. The pipeline is stdlib-only; the worker
# needs boto3 + requests.
COPY worker/requirements.txt /app/worker/requirements.txt
RUN pip install --no-cache-dir -r /app/worker/requirements.txt

# App code: both halves.
COPY pipeline /app/pipeline
COPY worker   /app/worker

ENV PIPELINE_DIR=/app/pipeline \
    WORKER_WORKDIR=/tmp/rendprop-worker \
    PYTHONUNBUFFERED=1

WORKDIR /app/worker

# Long-running poller by default. For a triggered/serverless run, override with:
#   docker run ... rendprop-worker python worker.py --once
#   docker run ... rendprop-worker python worker.py --job-id <uuid>
CMD ["python", "worker.py"]
