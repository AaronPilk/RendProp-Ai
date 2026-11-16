FROM python:3.13-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates fonts-liberation2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 renderer
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r /app/requirements.txt
COPY container/ /app/
RUN mkdir -p /work && chown renderer:renderer /work
USER 10001:10001
EXPOSE 8080
CMD ["python3", "http_adapter.py"]
