"""A single accepted aerial opening, then the unchanged full-photo motion shots.

No supplier calls, URL-only acceptance, crop, frame interpolation or timing repair.
The signed media descriptor is private input; only its frozen receipt is echoed.
"""
from __future__ import annotations

import datetime
import math
import re
import shutil
from pathlib import Path

from capabilities import digest, download
from compose import MusicSource, QualityError, probe, require_cfr24, run
from music_catalog import validate_music
from prepare_image import MAX_SOURCE_BYTES, normalize_full_resolution
from presentation import overlay
from photo_motion_profile import (MODE, PROFILE, OPENING_PROFILE, FPS, TASK_KEYS,
                                  checked_producer, validate_photo_motion_task,
                                  validate_photo_audio_task, encode_photo, mux_audio)

OPENING_FRAMES = {120, 121, 144, 192}
MAX_OPENING_BYTES = 128*1024*1024  # existing controller input capability bound
REF_KEYS = {"aerial_job_id", "asset_id", "provenance_id", "sha256", "bytes", "visible_frames", "source"}
RECEIPT_KEYS = REF_KEYS | {"schema", "kind", "position", "scope", "fps", "available_frames", "width", "height", "duration_s", "aspect", "disclosure", "accepted_at"}
SOURCE_KEYS = {"photo_asset_id", "photo_version_id", "photo_provenance_id", "sha256", "bytes"}
SCOPE_KEYS = {"actor_id", "org_id", "selected_library_org_id", "listing_id"}
HEX = re.compile(r"^[a-f0-9]{64}$")
UUID = re.compile(r"^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$")


def _uuid(value):
    return isinstance(value, str) and UUID.fullmatch(value) is not None


def validate_opening_receipt(receipt, aspect):
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise QualityError("closed_aerial_opening_receipt_required")
    source, scope = receipt["source"], receipt["scope"]
    width, height = (1920, 1080) if aspect == "16:9" else (1080, 1920)
    if (any(not _uuid(receipt[k]) for k in ("aerial_job_id", "asset_id", "provenance_id"))
            or receipt["schema"] != 1 or type(receipt["schema"]) is not int
            or receipt["kind"] != "aerial_opening" or type(receipt["position"]) is not int or receipt["position"] != 0
            or receipt["aspect"] != aspect or receipt["width"] != width or receipt["height"] != height
            or type(receipt["width"]) is not int or type(receipt["height"]) is not int
            or type(receipt["fps"]) is not int or receipt["fps"] != FPS
            or type(receipt["visible_frames"]) is not int or receipt["visible_frames"] not in OPENING_FRAMES
            or type(receipt["available_frames"]) is not int or receipt["available_frames"] != receipt["visible_frames"]
            or type(receipt["duration_s"]) not in (float, int) or receipt["duration_s"] != receipt["visible_frames"]/FPS
            or type(receipt["bytes"]) is not int or not 1 <= receipt["bytes"] <= MAX_OPENING_BYTES
            or not isinstance(receipt["sha256"], str) or HEX.fullmatch(receipt["sha256"]) is None
            or not isinstance(receipt["disclosure"], str) or not 1 <= len(receipt["disclosure"]) <= 2000
            or any(ord(c) < 32 for c in receipt["disclosure"])
            or not isinstance(scope, dict) or set(scope) != SCOPE_KEYS or any(not _uuid(scope[k]) for k in SCOPE_KEYS)
            or not isinstance(source, dict) or set(source) != SOURCE_KEYS
            or not _uuid(source["photo_asset_id"]) or source["photo_version_id"] != "asset:"+source["photo_asset_id"]
            or source["photo_provenance_id"] is not None and not _uuid(source["photo_provenance_id"])
            or not isinstance(source["sha256"], str) or HEX.fullmatch(source["sha256"]) is None
            or type(source["bytes"]) is not int or not 1 <= source["bytes"] <= MAX_SOURCE_BYTES):
        raise QualityError("exact_aerial_opening_identity_required")
    try:
        accepted = datetime.datetime.fromisoformat(receipt["accepted_at"].replace("Z", "+00:00"))
        if accepted.tzinfo is None:
            raise ValueError("timezone required")
    except (AttributeError, TypeError, ValueError, OverflowError) as error:
        raise QualityError("aerial_acceptance_time_required") from error
    return receipt


def validate_opening_task(task):
    if not isinstance(task, dict) or task.get("composition_profile") != OPENING_PROFILE or set(task) - (TASK_KEYS | {"opening"}):
        raise QualityError("closed_aerial_opening_task_required")
    opening = task.get("opening")
    if not isinstance(opening, dict) or set(opening) != {"receipt", "media"}:
        raise QualityError("one_accepted_aerial_opening_required")
    receipt = validate_opening_receipt(opening["receipt"], task.get("aspect"))
    media = opening["media"]
    if (not isinstance(media, dict) or set(media) != {"url", "sha256", "bytes", "etag"}
            or media["sha256"] != receipt["sha256"] or media["bytes"] != receipt["bytes"]
            or not isinstance(media["url"], str) or not isinstance(media["etag"], str) or not 1 <= len(media["etag"]) <= 512):
        raise QualityError("exact_aerial_opening_media_required")
    # The base branch remains the authority for all unchanged photo/presentation guards.
    base = {k: v for k, v in task.items() if k != "opening"}
    base["composition_profile"] = PROFILE
    frames = validate_photo_motion_task(base)
    return frames


def validate_opening_audio_task(task):
    # Audio inspection carries the exact admitted manifest and total timeline;
    # the backend freezes opening identity, not a second unsigned audio variant.
    duration = task.get("max_duration_s")
    if type(duration) not in (float, int) or not math.isfinite(duration) or not 7 <= duration <= 508:
        raise QualityError("bounded_aerial_audio_timeline_required")
    base = {**task, "composition_profile": PROFILE, "max_duration_s": min(duration, 500)}
    return validate_photo_audio_task(base)


def verified_opening_clip(source, receipt, destination):
    facts = probe(source)
    streams = facts.get("streams", [])
    if len(streams) != 1 or streams[0].get("codec_type") != "video":
        raise QualityError("silent_single_aerial_video_required")
    v = streams[0]
    rotation = any(int(s.get("rotation", 0)) != 0 for s in v.get("side_data_list", []))
    if (v.get("codec_name") != "h264" or v.get("pix_fmt") != "yuv420p"
            or (v.get("width"), v.get("height")) != (receipt["width"], receipt["height"])
            or v.get("sample_aspect_ratio", "1:1") != "1:1"
            or rotation or str(v.get("tags", {}).get("rotate", "0")) not in {"0", "0.0"}
            or tuple(v.get(k) for k in ("color_space", "color_transfer", "color_primaries")) != ("bt709", "bt709", "bt709")
            or abs(float(facts["format"]["duration"])-receipt["duration_s"]) > .001):
        raise QualityError("exact_aerial_video_format_required")
    require_cfr24(source, facts, exact_frames={receipt["visible_frames"]})
    # Match the photo encoder's H264/timebase without changing size, frame cadence,
    # frame count or content boundaries. The immutable input is not modified.
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", str(source),
         "-map", "0:v:0", "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-maxrate", "24M", "-bufsize", "48M", "-threads", "2",
         "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movie_timescale", "24000", "-video_track_timescale", "24000", "-movflags", "+faststart", str(destination)])
    require_cfr24(destination, probe(destination), exact_frames={receipt["visible_frames"]})


def render_opening_task(task, directory, hosts):
    frames = validate_opening_task(task)
    receipt = task["opening"]["receipt"]
    width, height = receipt["width"], receipt["height"]
    opening_frames = receipt["visible_frames"]
    starts = [(opening_frames+sum(frames[:n]))/FPS for n in range(len(frames))]
    total_frames = opening_frames+sum(frames)
    elapsed = total_frames/FPS
    from renderer import expiry
    expiry(task["expires_at"])
    raw_opening, first = directory/"accepted-opening.mp4", directory/"opening.mp4"
    download(task["opening"]["media"], raw_opening, hosts, max_bytes=MAX_OPENING_BYTES)
    input_sha = digest(raw_opening)
    verified_opening_clip(raw_opening, receipt, first)
    if digest(raw_opening) != input_sha or input_sha != receipt["sha256"]:
        raise QualityError("aerial_source_changed_during_compose")
    raw_opening.unlink()
    clips, source_hashes = [first], []
    presentation = task["presentation"]
    for position, source in enumerate(task["sources"]):
        expiry(task["expires_at"])
        photo, normalized = directory/f"photo-{position:03d}", directory/f"oriented-{position:03d}.png"
        source_hashes.append(download(source, photo, hosts, max_bytes=MAX_SOURCE_BYTES))
        normalize_full_resolution(photo, normalized)
        photo.unlink()
        clip = directory/f"shot-{position:03d}.mp4"
        encode_photo(normalized, clip, task["aspect"], frames[position], source["motion"])
        normalized.unlink()
        labels = presentation.get("shot_labels", [])
        if labels and labels[position] is not None:
            label_dir = directory/f"label-{position:03d}"
            label_dir.mkdir()
            local = {**presentation, "title_card": None, "spoken_captions": False, "shot_labels": [labels[position]]}
            clip = overlay(clip, label_dir, width, height, local, [0], frames[position]/FPS, [], fps=FPS)
        # Concatenation requires one MP4 timestamp unit. Remux photo packets
        # losslessly; do not change frame cadence, count, pixels or duration.
        canonical = directory/f"timeline-{position:03d}.mp4"
        run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", str(clip),
             "-map", "0:v:0", "-an", "-c:v", "copy", "-video_track_timescale", "24000", "-movflags", "+faststart", str(canonical)])
        require_cfr24(canonical, probe(canonical), exact_frames={frames[position]})
        clips.append(canonical)
    concat, clean = directory/"concat.txt", directory/"clean.mp4"
    concat.write_text("".join(f"file '{p.relative_to(directory).as_posix()}'\n" for p in clips))
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "concat", "-safe", "1", "-protocol_whitelist", "file,pipe", "-i", str(concat),
         "-map", "0:v:0", "-an", "-c:v", "copy", "-movie_timescale", "24000", "-movflags", "+faststart", str(clean)])
    narration = None
    if task.get("narration"):
        narration = directory/"voice.m4a"
        download(task["narration"], narration, hosts)
    music = None
    if task.get("music"):
        selection = task["music"]
        track = validate_music(selection)
        audio = directory/"music.m4a"
        download({"url":selection["url"], "bytes":selection["bytes"], "sha256":selection["asset_sha256"]}, audio, hosts)
        music = MusicSource(selection["track_id"], audio, selection["asset_sha256"], "CC0-1.0", track["credit"])
    global_presentation = {**presentation, "shot_caption_style": "off", "shot_labels": []}
    visual = overlay(clean, directory, width, height, global_presentation, starts, elapsed, (task.get("narration") or {}).get("words", []), fps=FPS)
    master = directory/"master.mp4"
    mux_audio(visual, master, elapsed, narration, music)
    facts = probe(master)
    videos = [v for v in facts["streams"] if v["codec_type"] == "video"]
    if len(videos) != 1 or (videos[0]["width"], videos[0]["height"]) != (width, height) or abs(float(facts["format"]["duration"])-elapsed) > .001:
        raise QualityError("aerial_photo_final_geometry_duration_refused")
    require_cfr24(master, facts, exact_frames={total_frames})
    poster = directory/"poster.jpg"
    from aerial_processing import jpeg_frame
    jpeg_frame(master, 0, poster, width, height)
    output = task["output"]
    result = {"job_id":task["job_id"], "lease_token":task["lease_token"], "manifest_sha256":task["manifest_sha256"],
              "asset_id":output["asset_id"], "poster_asset_id":output["poster_asset_id"], "width":width, "height":height,
              "duration_s":elapsed, "fps":FPS, "bytes":master.stat().st_size, "sha256":digest(master), "poster_bytes":poster.stat().st_size, "poster_sha256":digest(poster),
              "source_mode":MODE, "composition_profile":OPENING_PROFILE, "total_frames":total_frames,
              "source_frames":frames, "source_sha256s":source_hashes, "source_motions":[s["motion"] for s in task["sources"]],
              "opening":receipt, "producer_identity":checked_producer(task)}
    return {"receipt":result, "master":master, "poster":poster}
