"""Explicit, deterministic photo motion. Never an AI-clip recovery path.

The old renderer and five-second composer are unchanged. This profile uses
only the selected photo's pixels and an exact, immutable 24fps shot timeline.
"""
from __future__ import annotations

import math
import json
import os
import re
import shutil
from pathlib import Path

from PIL import Image

from capabilities import digest, download
from compose import MusicSource, QualityError, probe, require_cfr24, run
from music_catalog import validate_music
from prepare_image import MAX_SOURCE_BYTES, normalize_full_resolution
from presentation import overlay
from process_deadline import BoundedProcess, ProcessDeadlineError

MODE = "photo_motion_v1"
PROFILE = "photo-motion-v2-cfr24"
OPENING_PROFILE = "photo-motion-v2-opening-cfr24"
FRAME_CHOICES = {48, 72, 96, 120}
FPS = 24
MOTIONS = {"push_in", "pull_back", "slide_left", "slide_right"}
SOURCE_KEYS = {"url", "sha256", "bytes", "etag", "position", "motion_kind", "motion", "visible_frames"}
TASK_KEYS = {"state", "action", "job_id", "lease_token", "manifest_sha256", "purpose", "aspect", "composition_profile", "source_mode", "sources", "narration", "music", "presentation", "output", "expires_at", "producer_identity"}


def checked_producer(task):
    raw = os.environ.get("PHOTO_MOTION_PRODUCER_IDENTITY", "")
    if not raw or len(raw) > 1024:
        raise QualityError("photo_motion_producer_required")
    try:
        producer = json.loads(raw)
    except ValueError as error:
        raise QualityError("photo_motion_producer_required") from error
    if (not isinstance(producer, dict) or set(producer) != {"image_uri", "controller_sha256", "renderer_source_sha256"}
            or producer != task.get("producer_identity")
            or not isinstance(producer["image_uri"], str) or len(producer["image_uri"]) > 512
            or not re.fullmatch(r"registry\.cloudflare\.com/9c332c75b96cc642621dad5d86d4bf18/[a-z0-9._/-]+@sha256:[a-f0-9]{64}", producer["image_uri"])
            or producer["image_uri"] == "registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-cpu@sha256:4452a0488ae786dff4e607d11e4711af5a2d59e4d6d26f168d9063db039774bc"
            or any(not isinstance(producer[k], str) or len(producer[k]) != 64 or any(c not in "0123456789abcdef" for c in producer[k]) for k in ("controller_sha256", "renderer_source_sha256"))
            or producer["renderer_source_sha256"] != digest(Path(__file__))):
        raise QualityError("photo_motion_producer_conflict")
    return producer


def validate_photo_audio_task(task):
    if isinstance(task, dict) and task.get("composition_profile") == OPENING_PROFILE:
        from aerial_opening_profile import validate_opening_audio_task
        return validate_opening_audio_task(task)
    keys = {"state", "action", "job_id", "lease_token", "manifest_sha256", "source", "max_duration_s", "expires_at", "source_mode", "composition_profile", "producer_identity"}
    if set(task) - keys or task.get("source_mode") != MODE or task.get("composition_profile") != PROFILE or task.get("action") != "inspect_audio":
        raise QualityError("closed_photo_audio_profile_required")
    checked_producer(task)
    source, duration, sha = task.get("source"), task.get("max_duration_s"), task.get("manifest_sha256")
    if (not isinstance(source, dict) or set(source) != {"url", "sha256", "bytes", "etag"}
            or type(source["bytes"]) is not int or not 1 <= source["bytes"] <= 20*1024*1024
            or not isinstance(source["sha256"], str) or len(source["sha256"]) != 64 or any(c not in "0123456789abcdef" for c in source["sha256"])
            or not isinstance(source["etag"], str) or not 1 <= len(source["etag"]) <= 512 or not isinstance(source["url"], str)
            or isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 2 <= duration <= 500
            or not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)):
        raise QualityError("bounded_photo_audio_required")


def validate_photo_motion_task(task):
    if isinstance(task, dict) and task.get("composition_profile") in {"aerial-opening-input-v1", "aerial-opening-qualify-cfr24"}:
        from aerial_processing import validate_task
        return validate_task(task)
    if isinstance(task, dict) and task.get("composition_profile") == OPENING_PROFILE:
        from aerial_opening_profile import validate_opening_task
        return validate_opening_task(task)
    if (not isinstance(task, dict) or set(task) - TASK_KEYS
            or task.get("action") != "compose" or task.get("source_mode") != MODE
            or task.get("composition_profile") != PROFILE):
        raise QualityError("closed_photo_motion_profile_required")
    checked_producer(task)
    sha = task.get("manifest_sha256")
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        raise QualityError("manifest_required")
    if task.get("purpose") not in {"listing", "social"} or task.get("aspect") != ("16:9" if task["purpose"] == "listing" else "9:16"):
        raise QualityError("purpose_aspect_conflict")
    sources = task.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= 100:
        raise QualityError("bounded_source_count")
    for position, source in enumerate(sources):
        if (not isinstance(source, dict) or set(source) != SOURCE_KEYS
                or type(source["position"]) is not int or source["position"] != position
                or source["motion_kind"] != "photo_motion" or source["motion"] not in MOTIONS
                or type(source["visible_frames"]) is not int or source["visible_frames"] not in FRAME_CHOICES
                or type(source["bytes"]) is not int or not 1 <= source["bytes"] <= MAX_SOURCE_BYTES
                or not isinstance(source["sha256"], str) or len(source["sha256"]) != 64
                or any(c not in "0123456789abcdef" for c in source["sha256"])
                or not isinstance(source["etag"], str) or not 1 <= len(source["etag"]) <= 512
                or not isinstance(source["url"], str)):
            raise QualityError("closed_photo_motion_source_required")
    presentation = task.get("presentation")
    if not isinstance(presentation, dict) or presentation.get("transition") != "cut":
        raise QualityError("photo_motion_requires_cut")
    if (set(presentation) - {"transition", "shot_caption_style", "spoken_captions", "title_card", "shot_labels"}
            or presentation.get("shot_caption_style", "off") not in {"off", "lowerThird", "punchCard", "highlightBox"}
            or type(presentation.get("spoken_captions", False)) is not bool
            or not isinstance(presentation.get("shot_labels", []), list)):
        raise QualityError("closed_photo_presentation_required")
    if task["purpose"] == "listing" and presentation.get("title_card"):
        raise QualityError("listing_branding_refused")
    if len(presentation.get("shot_labels", [])) not in {0, len(sources)}:
        raise QualityError("caption_identity_conflict")
    validate_music(task.get("music"))
    # The outer renderer validates the existing UUID, expiry and output IDs.
    return [source["visible_frames"] for source in sources]


def source_box(source_width, source_height, width, height, frame, frames, motion="push_in"):
    if type(frames) is not int or frames not in FRAME_CHOICES or type(frame) is not int or not 0 <= frame < frames:
        raise QualityError("closed_photo_motion_frames_required")
    if motion not in MOTIONS:
        raise QualityError("closed_photo_motion_direction_required")
    crop_width = min(source_width, source_height * width / height)
    crop_height = crop_width * height / width
    progress = .5 - .5 * math.cos(math.pi * frame / (frames - 1))
    zoom = (1 + .12 * progress) if motion == "push_in" else (1.12 - .12 * progress) if motion == "pull_back" else 1.12
    cw, ch = crop_width / zoom, crop_height / zoom
    if cw < width or ch < height:
        raise QualityError("photo_motion_lacks_native_pixels")
    # Pan only inside the centered aspect crop: range = .12 visible widths.
    x = (source_width-crop_width)/2 + (crop_width-cw) * (1-progress if motion == "slide_left" else progress) if motion in {"slide_left", "slide_right"} else (source_width-cw)/2
    y = (source_height-ch)/2
    return (x, y, x+cw, y+ch)


def encode_photo(photo, clip, aspect, frames, motion="push_in"):
    width, height = (1920, 1080) if aspect == "16:9" else (1080, 1920)
    with Image.open(photo) as decoded:
        if decoded.format != "PNG" or decoded.mode != "RGB" or getattr(decoded, "n_frames", 1) != 1:
            raise QualityError("normalized_photo_required")
        decoded.load()
        image = decoded.copy()
    # Validate the entire transform before starting a codec process.
    boxes = [source_box(image.width, image.height, width, height, n, frames, motion) for n in range(frames)]
    args = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
            "-framerate", "24", "-protocol_whitelist", "file,pipe", "-i", "pipe:0", "-an", "-frames:v", str(frames),
            "-vf", "format=gbrp,colorspace=ispace=gbr:itrc=srgb:iprimaries=bt709:irange=pc:space=bt709:trc=bt709:primaries=bt709:range=tv:format=yuv420p",
            "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-maxrate", "24M", "-bufsize", "48M", "-threads", "2",
            "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-movie_timescale", "24000", "-movflags", "+faststart", str(clip)]
    try:
        with BoundedProcess(args, timeout=300, write_stdin=True) as process:
            for box in boxes:
                frame = image.transform((width, height), Image.Transform.EXTENT, box, resample=Image.Resampling.BICUBIC)
                process.write(frame.tobytes())
            if process.finish() != 0:
                raise QualityError("photo_motion_encode_failed")
    except ProcessDeadlineError as error:
        raise QualityError("photo_motion_encode_deadline") from error
    require_cfr24(clip, probe(clip), exact_frames={frames})


def mux_audio(visual, master, elapsed, narration=None, music=None):
    """Reuse the existing audio policy, bounded by the actual photo timeline."""
    args = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", str(visual)]
    if narration is not None:
        audio = probe(narration)
        if len([s for s in audio["streams"] if s["codec_type"] == "audio"]) != 1:
            raise QualityError("one_verified_narration_stream_required")
        voice_duration = float(audio["format"]["duration"])
        if not math.isfinite(voice_duration) or voice_duration > elapsed:
            raise QualityError("narration_exceeds_photo_timeline")
        args += ["-protocol_whitelist", "file,pipe", "-i", str(narration)]
    if music is not None:
        if digest(music.path) != music.sha256 or not music.track_id or not music.license_revision:
            raise QualityError("licensed_music_identity_required")
        if len([s for s in probe(music.path)["streams"] if s["codec_type"] == "audio"]) != 1:
            raise QualityError("one_verified_music_stream_required")
        args += ["-stream_loop", "-1", "-protocol_whitelist", "file,pipe", "-i", str(music.path)]
        music_index = 2 if narration is not None else 1
        chain = f"[{music_index}:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.18,atrim=duration={elapsed},asetpts=PTS-STARTPTS[m]"
        if narration is not None:
            ratio = .07/.18
            chain += (f";[1:a]aresample=48000,aformat=channel_layouts=stereo,apad,atrim=duration={elapsed},asetpts=PTS-STARTPTS,asplit=2[n][side]"
                      f";[side]anullsink;[m]volume='if(lt(t,{voice_duration}),{ratio},1)':eval=frame[ducked]"
                      ";[n][ducked]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0")
        else:
            chain += ";[m]anull"
        chain += ",alimiter=limit=0.95:level=0:latency=1[a]"
        args += ["-filter_complex", chain, "-map", "0:v:0", "-map", "[a]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
    elif narration is not None:
        args += ["-map", "0:v:0", "-map", "1:a:0", "-af", "apad", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
    else:
        args += ["-map", "0:v:0", "-an"]
    args += ["-c:v", "copy", "-t", str(elapsed), "-movie_timescale", "24000", "-movflags", "+faststart", str(master)]
    run(args)


def render_photo_motion_task(task, directory, hosts):
    if isinstance(task, dict) and task.get("composition_profile") in {"aerial-opening-input-v1", "aerial-opening-qualify-cfr24"}:
        from aerial_processing import prepare_source, qualify_clip
        return prepare_source(task, directory, hosts) if task["composition_profile"] == "aerial-opening-input-v1" else qualify_clip(task, directory, hosts)
    if isinstance(task, dict) and task.get("composition_profile") == OPENING_PROFILE:
        from aerial_opening_profile import render_opening_task
        return render_opening_task(task, directory, hosts)
    frames = validate_photo_motion_task(task)
    width, height = (1920, 1080) if task["aspect"] == "16:9" else (1080, 1920)
    starts = [sum(frames[:n])/FPS for n in range(len(frames))]
    elapsed = sum(frames)/FPS
    presentation = task["presentation"]
    clips = []
    source_hashes = []
    for position, source in enumerate(task["sources"]):
        # The unchanged downloader verifies exact signed size and SHA; the
        # outer task expires before admission and each individual download.
        from renderer import expiry
        expiry(task["expires_at"])
        photo = directory/f"photo-{position:03d}"
        source_hashes.append(download(source, photo, hosts, max_bytes=MAX_SOURCE_BYTES))
        normalized = directory/f"oriented-{position:03d}.png"
        normalize_full_resolution(photo, normalized)
        photo.unlink()
        clip = directory/f"shot-{position:03d}.mp4"
        encode_photo(normalized, clip, task["aspect"], frames[position], source["motion"])
        normalized.unlink()
        # Existing overlay is scoped to this shot's actual duration, avoiding
        # its legacy five-second label end crossing into the next photo.
        labels = presentation.get("shot_labels", [])
        if labels and labels[position] is not None:
            label_dir = directory/f"label-{position:03d}"
            label_dir.mkdir()
            local = {**presentation, "title_card": ({"title":"", "subtitle":"", "watermark":""} if position == 0 and presentation.get("title_card") else None),
                     "spoken_captions": False, "shot_labels": [labels[position]]}
            clip = overlay(clip, label_dir, width, height, local, [0], frames[position]/FPS, [], fps=FPS)
        clips.append(clip)
    concat = directory/"concat.txt"
    # All paths are renderer-controlled, not caller text.
    concat.write_text("".join(f"file '{p.relative_to(directory).as_posix()}'\n" for p in clips))
    clean = directory/"clean.mp4"
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
        path = directory/"music.m4a"
        download({"url":selection["url"], "bytes":selection["bytes"], "sha256":selection["asset_sha256"]}, path, hosts)
        music = MusicSource(selection["track_id"], path, selection["asset_sha256"], "CC0-1.0", track["credit"])
    global_presentation = {**presentation, "shot_caption_style":"off", "shot_labels":[]}
    visual = overlay(clean, directory, width, height, global_presentation, starts, elapsed, (task.get("narration") or {}).get("words", []), fps=FPS)
    master = directory/"master.mp4"
    mux_audio(visual, master, elapsed, narration, music)
    facts = probe(master)
    videos = [v for v in facts["streams"] if v["codec_type"] == "video"]
    if len(videos) != 1 or (videos[0]["width"], videos[0]["height"]) != (width, height) or abs(float(facts["format"]["duration"])-elapsed) > .001:
        raise QualityError("photo_motion_final_geometry_duration_refused")
    require_cfr24(master, facts, exact_frames={sum(frames)})
    poster = directory/"poster.jpg"
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", "0.25", "-protocol_whitelist", "file,pipe", "-i", str(master), "-frames:v", "1", "-q:v", "2", str(poster)], timeout=30)
    output = task["output"]
    receipt = {"job_id":task["job_id"], "lease_token":task["lease_token"], "manifest_sha256":task["manifest_sha256"],
               "asset_id":output["asset_id"], "poster_asset_id":output["poster_asset_id"], "width":width, "height":height,
               "duration_s":elapsed, "fps":FPS, "bytes":master.stat().st_size, "sha256":digest(master),
               "poster_bytes":poster.stat().st_size, "poster_sha256":digest(poster),
               "source_mode":MODE, "composition_profile":PROFILE, "total_frames":sum(frames),
               "source_frames":frames, "source_sha256s":source_hashes, "source_motions":[s["motion"] for s in task["sources"]], "producer_identity":checked_producer(task)}
    return {"receipt":receipt, "master":master, "poster":poster}
