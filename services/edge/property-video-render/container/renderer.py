"""Trusted Edge task -> measured CPU receipt; never publishes a property."""
import base64
import datetime
import math
import shutil
import tempfile
import time
import uuid
from pathlib import Path

from capabilities import download, upload, digest
from prepare_image import prepare_image, normalize_full_resolution, MAX_SOURCE_BYTES
from photo_motion import encode_photo_motion
from photo_quality import validate_photo_task, prepare_photo_quality, upload_photo_quality
from compose import MusicSource, QualityError, compose, probe, run
from music_catalog import validate_music

MAX_INPUT_BYTES = 8 * 1024 * 1024 * 1024


def uuid_value(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("invalid_task_identity")
    return value


def expiry(value):
    if not isinstance(value, str):
        raise ValueError("expiry_required")
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.timestamp() <= time.time():
        raise ValueError("stale_task")


def validate_task(task):
    if task.get("action") == "prepare_photo_quality":
        validate_photo_task(task)
        return
    uuid_value(task["job_id"])
    uuid_value(task["lease_token"])
    expiry(task["expires_at"])
    if task["action"] not in {"extract_frames", "compose", "prepare_image", "inspect_audio"}:
        raise ValueError("unsupported_cpu_action")
    if task["action"] == "inspect_audio":
        if set(task) - {"state", "action", "job_id", "lease_token", "manifest_sha256", "source", "max_duration_s", "expires_at"}:
            raise ValueError("closed_cpu_task")
        source, sha, duration = task["source"], task["manifest_sha256"], task["max_duration_s"]
        if (not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)
                or not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(duration) or not 1 <= duration <= 500
                or not isinstance(source["bytes"], int) or isinstance(source["bytes"], bool) or not 1 <= source["bytes"] <= 20 * 1024 * 1024
                or not isinstance(source["sha256"], str) or len(source["sha256"]) != 64 or any(c not in "0123456789abcdef" for c in source["sha256"])):
            raise ValueError("bounded_owned_narration_required")
    elif task["action"] == "prepare_image":
        if set(task) - {"state", "action", "job_id", "lease_token", "source", "output", "expires_at"}:
            raise ValueError("closed_cpu_task")
        uuid_value(task["output"]["asset_id"])
        source = task["source"]
        if (not isinstance(source["bytes"], int) or isinstance(source["bytes"], bool)
                or not 1 <= source["bytes"] <= MAX_SOURCE_BYTES
                or not isinstance(source["sha256"], str) or len(source["sha256"]) != 64
                or any(c not in "0123456789abcdef" for c in source["sha256"])):
            raise ValueError("bounded_owned_photo_required")
    elif task["action"] == "extract_frames":
        uuid_value(task["attempt_id"])
        if set(task) - {"state", "action", "job_id", "attempt_id", "lease_token", "source", "clip", "expires_at"}:
            raise ValueError("closed_cpu_task")
    else:
        if set(task) - {"state", "action", "job_id", "lease_token", "manifest_sha256", "purpose", "aspect", "sources", "narration", "music", "presentation", "output", "expires_at"}:
            raise ValueError("closed_cpu_task")
        sha = task["manifest_sha256"]
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise ValueError("manifest_required")
        if task["purpose"] not in {"listing", "social"} or task["aspect"] != ("16:9" if task["purpose"] == "listing" else "9:16"):
            raise ValueError("purpose_aspect_conflict")
        sources = task["sources"]
        if not isinstance(sources, list) or not 1 <= len(sources) <= 100:
            raise ValueError("bounded_source_count")
        if [item["position"] for item in sources] != list(range(len(sources))):
            raise ValueError("frozen_order_required")
        if sum(item["bytes"] for item in sources) > MAX_INPUT_BYTES:
            raise ValueError("bounded_input_disk")
        validate_music(task.get("music"))
        presentation = task.get("presentation") or {}
        if task["purpose"] == "listing" and (presentation.get("title_card")):
            raise ValueError("listing_branding_refused")
        for key in {"asset_id", "poster_asset_id"}:
            uuid_value(task["output"][key])


def inspect_audio(task, directory, hosts):
    source = directory / "narration.bin"
    sha = download(task["source"], source, hosts, max_bytes=20 * 1024 * 1024)
    facts = probe(source)
    streams = facts.get("streams", [])
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(audio) != 1:
        raise QualityError("one_narration_stream_required")
    duration = float(facts.get("format", {}).get("duration", 0))
    if not math.isfinite(duration) or not .01 <= duration <= 3600:
        raise QualityError("narration_duration_required")
    # Read the real audio packets before any paid clip. Extra album-art streams
    # are ignored just as they are by the final audio-only mux.
    run([shutil.which("ffmpeg"), "-v", "error", "-nostdin", "-xerror", "-err_detect", "explode", "-i", str(source),
         "-map", "0:a:0", "-vn", "-sn", "-dn", "-f", "null", "-"], timeout=60)
    # A valid but overlong narration is reported to the fenced authority. It is
    # a definitive user correction, not three retries of the same CPU probe.
    source.unlink()
    return {"job_id": task["job_id"], "lease_token": task["lease_token"], "manifest_sha256": task["manifest_sha256"],
            "source_sha256": sha, "duration_s": duration, "audio_streams": 1}


def extract(task, directory, hosts):
    clip = directory / "clip.mp4"
    sha = download(task["clip"], clip, hosts, hash_optional=True)
    facts = probe(clip)
    videos = [s for s in facts["streams"] if s["codec_type"] == "video"]
    if len(videos) != 1:
        raise QualityError("one_clip_required")
    video = videos[0]
    duration = float(facts["format"]["duration"])
    if (not 4.97 <= duration <= 5.08 or video["width"] * video["height"] > 33177600
            or min(video["width"], video["height"]) < 1080):
        raise QualityError("clip_geometry_refused")
    frames = []
    for i, position in enumerate((.25, duration / 2, duration - .25)):
        image = directory / f"frame-{i}.jpg"
        run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", str(position),
             "-i", str(clip), "-frames:v", "1", "-vf", "scale=1024:1024:force_original_aspect_ratio=decrease", "-q:v", "3", str(image)], timeout=30)
        if image.stat().st_size > 384 * 1024:
            raise QualityError("bounded_qc_frame")
        frames.append({"image_b64": base64.b64encode(image.read_bytes()).decode(), "mime": "image/jpeg"})
    return {"job_id": task["job_id"], "attempt_id": task["attempt_id"], "lease_token": task["lease_token"],
            "frames": frames, "clip_sha256": sha, "width": video["width"], "height": video["height"], "duration_s": duration}


def compose_task(task, directory, hosts):
    clips = []
    for i, source in enumerate(task["sources"]):
        expiry(task["expires_at"])
        clip = directory / f"input-{i:03d}.mp4"
        if source["motion_kind"] == "original_photo":
            photo = directory / f"input-{i:03d}.jpg"
            download(source, photo, hosts, max_bytes=MAX_SOURCE_BYTES)
            normalized = directory / f"input-{i:03d}-oriented.png"
            normalize_full_resolution(photo, normalized)
            photo.unlink()
            encode_photo_motion(normalized, clip, task["aspect"], source["motion"])
            normalized.unlink()
        elif source["motion_kind"] == "ai":
            download(source, clip, hosts)
        else:
            raise ValueError("unknown_motion_kind")
        clips.append(clip)
    narration = None
    if task.get("narration"):
        narration = directory / "voice.m4a"
        download(task["narration"], narration, hosts)
    music = None
    selection = task.get("music")
    if selection:
        track = validate_music(selection)
        path = directory / "music.m4a"
        download({"url": selection["url"], "bytes": selection["bytes"], "sha256": selection["asset_sha256"]}, path, hosts)
        music = MusicSource(selection["track_id"], path, selection["asset_sha256"], "CC0-1.0", track["credit"])
    result = compose(clips, directory / "output", aspect=task["aspect"], narration=narration,
                     music=music, music_gain=.18, duck_gain=.07,
                     presentation=task.get("presentation"), words=(task.get("narration") or {}).get("words", []), discard_inputs=True)
    output = task["output"]
    receipt = {"job_id": task["job_id"], "lease_token": task["lease_token"], "manifest_sha256": task["manifest_sha256"],
            "asset_id": output["asset_id"], "poster_asset_id": output["poster_asset_id"],
            "width": result["width"], "height": result["height"], "duration_s": result["duration_s"],
            "bytes": result["master"].stat().st_size, "sha256": digest(result["master"]),
            "poster_bytes": result["poster"].stat().st_size, "poster_sha256": digest(result["poster"])}
    return {"receipt": receipt, "master": result["master"], "poster": result["poster"]}


def render(task, hosts, work_root="/work"):
    validate_task(task)
    if shutil.disk_usage(work_root).free < 3 * 1024 * 1024 * 1024:
        raise QualityError("insufficient_private_work_disk")
    directory = Path(tempfile.mkdtemp(prefix="render-", dir=work_root))
    try:
        result = prepare_photo_quality(task, directory, hosts) if task["action"] == "prepare_photo_quality" else inspect_audio(task, directory, hosts) if task["action"] == "inspect_audio" else prepare_image(task, directory, hosts) if task["action"] == "prepare_image" else extract(task, directory, hosts) if task["action"] == "extract_frames" else compose_task(task, directory, hosts)
        return {"result": result, "directory": directory}
    except BaseException:
        shutil.rmtree(directory, ignore_errors=True)
        raise


def upload_prepared(prepared, output, hosts):
    if "photo_quality_images" in prepared["result"]:
        return upload_photo_quality(prepared, output, hosts)
    expiry(output["expires_at"])
    receipt = prepared["result"]["receipt"]
    if "prepared_image" in prepared["result"]:
        if output["asset_id"] != receipt["asset_id"] or output.get("bytes", receipt["bytes"]) != receipt["bytes"]:
            raise ValueError("output_identity_conflict")
        upload(output["put_url"], prepared["result"]["prepared_image"], "image/jpeg", hosts, output["headers"])
        return receipt
    if (output["asset_id"] != receipt["asset_id"] or output["poster_asset_id"] != receipt["poster_asset_id"]
            or output.get("bytes", receipt["bytes"]) != receipt["bytes"]
            or output.get("poster_bytes", receipt["poster_bytes"]) != receipt["poster_bytes"]):
        raise ValueError("output_identity_conflict")
    upload(output["put_url"], prepared["result"]["master"], "video/mp4", hosts, output["headers"])
    upload(output["poster_put_url"], prepared["result"]["poster"], "image/jpeg", hosts, output["poster_headers"])
    return receipt
